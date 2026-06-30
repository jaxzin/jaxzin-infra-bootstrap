# Runbook: Gitea stack reconcile + daemon-restart survival

## What this is

Two cooperating Ansible roles keep the Gitea stack alive across an **out-of-band
Container Manager / Docker daemon restart** (a DSM auto-update, a package repair,
a manual bounce):

- **`container_manager_config`** — *prevention.* Enables Docker `live-restore`
  (and pins the `json-file` log-driver default) so a daemon restart no longer
  stops the running containers.
- **`stack_reconcile`** — *self-healing.* A watchdog that revives the stack if
  containers are still orphaned, without corrupting the weekly backup.

Both run in `gitea-deploy.yml` Play 1 (`hosts: nas`, `become: true`). Both are
best-effort and **DR-first** — a reconcile or daemon-config hiccup never fails
the deploy.

## The problem it solves (the 2026-06-30 gitea-db orphan incident)

A Container Manager / Docker daemon restart (most likely a DSM auto-update —
`pkg_autoupdate_important=yes`) tore down the stack. `gitea-db` is a slow-shutdown
container that exits **after** the daemon has already gone, so Docker's
`restart=always` policy — which only re-launches containers the daemon itself
stopped — never brought it back. `gitea` then crash-looped against the missing
database for **~3.5 hours** until someone intervened.

Two gaps caused this:

1. The daemon restart stopped containers at all. `live-restore` closes that gap.
2. Nothing watched for and revived an orphan that `restart=always` missed.
   `stack_reconcile` closes that one.

## Two layers of defense

### Layer 1 — `live-restore` (prevention)

`container_manager_config` merges `live-restore: true` (and the `json-file`
log-driver default) into the Synology Container Manager `dockerd.json`
(`/var/packages/ContainerManager/etc/dockerd.json`) without clobbering any
other keys, then applies it via a non-disruptive `dockerd` SIGHUP reload. With
`live-restore` active, a dockerd restart leaves the running containers up — the
orphan never happens. See the **live-restore caveat** below: SIGHUP does not
always flip it on this DSM build, so the role verifies and warns.

### Layer 2 — `stack_reconcile` (self-healing)

If an orphan still occurs (e.g. before the one-time live-restore enablement
completes, or some other path stops a container), the reconcile watchdog brings
the stack back within minutes.

## How `stack_reconcile` works

The same host-neutral reconcile script (`stack_reconcile.sh`) runs in **two
redundant contexts**:

- **Watchdog container** (`stack-reconcile`, `restart=always`) — a fast loop
  (`stack_reconcile_interval_seconds`, default **~30s**) that talks to the
  bind-mounted `/var/run/docker.sock`. This is the primary, fast healer.
- **Root host-cron fallback** (`stack_reconcile_cron_minute`, default **`*/2`**
  → ~2 min) — runs the same script from the Synology host. This is the **only**
  driver that can revive the **watchdog container itself** if it gets orphaned
  (a container cannot restart its own dead self). The cron driver alone sets
  `RECONCILE_ENSURE_CONTAINER`; the container loop deliberately does not.

Each pass does, in order:

1. **Honor the maintenance lock.** If the lock file is present, stand down
   immediately (see *The maintenance-lock contract*).
2. **Ensure the watchdog is running** (cron context only) — restart the
   `stack-reconcile` container if it is not running.
3. **Revive orphaned `restart=always` containers, in dependency order.** The
   managed list (`stack_reconcile_containers`) is
   **`tailscale-gitea gitea-db gitea`** — revival order matters:
   `tailscale-gitea` first (gitea runs with
   `network_mode: container:tailscale-gitea`, so it cannot start before the
   sidecar provides the network namespace), then `gitea-db`, then `gitea`.
   A container is only started if it is not running, its restart policy is
   `always`, and it has been down longer than the **debounce** window
   (`stack_reconcile_debounce_seconds`, default **90s**) — younger stops are
   left alone so the watchdog never fights a normal in-progress restart. (If
   the stop age can't be parsed at all, the container is started anyway rather
   than left dead, relying on the lock + `restart=always` guards as the safety
   net.)
4. **Dependency-gate / crash-loop break.** If the gate (`gitea`) is **running
   but `unhealthy`** while its dependency (`gitea-db`) is **healthy**, give
   `gitea` exactly one clean restart so it stops crash-looping against what was
   a missing DB. It keys on `unhealthy` specifically (not merely "not healthy")
   so a container still in its healthcheck `start_period` is left alone — a
   restart there would reset `start_period` and thrash `gitea` every loop.

The script always exits 0 (best-effort; a reconcile error must never cascade
into the DR-first Gitea stack). Corrective actions (`docker start` / `docker
restart`) are the only side effects, and each emits one log line plus an
optional Discord alert.

## The maintenance-lock contract

The weekly backup (`gitea_dump.sh`) **intentionally stops** the stack to take a
consistent dump. Without coordination, reconcile would see a stopped `gitea`,
call it an orphan, and fight the backup. The lock prevents that:

- **Lock file:** `{{ gitea_data_path }}/run/.reconcile-pause`. This single value
  is shared byte-for-byte between the two roles
  (`stack_reconcile_lock_path` ⇔ `gitea_backup_reconcile_lock_path`); they must
  match or the contract breaks. It lives in a dedicated, secret-free `run/`
  directory (not `scripts/`, which holds B2 + OpenBao credential env-files) so
  the watchdog can bind-mount just that directory read-only to see the lock
  without gaining access to other secrets.
- **Acquire:** `gitea_dump.sh` arms its `cleanup` trap (`EXIT INT TERM`) **first**,
  then creates the lock (`: > "$RECONCILE_LOCK"`) right before stopping the
  stack.
- **Release:** `cleanup()` removes the lock **last**, only after it has restarted
  Gitea. This is deliberate, not an early release: because reconcile stands down
  while the lock exists, releasing it before the backup's own `docker start`
  would let the watchdog race the backup's restart on the failure path.
- **Reconcile as the safety net:** the trap fires on **any** exit, so even if a
  dump dies mid-way the lock is still cleared — at which point reconcile resumes
  and becomes the safety net that brings the stack back up.

### Manually pause / resume reconcile

To pause reconcile (e.g. for hands-on maintenance on the NAS), create the lock:

```sh
mkdir -p {{ gitea_data_path }}/run
: > {{ gitea_data_path }}/run/.reconcile-pause
```

Both the watchdog and the host-cron will log `maintenance lock present … —
skipping` and take no action. To resume, remove it:

```sh
rm -f {{ gitea_data_path }}/run/.reconcile-pause
```

> Do **not** leave the lock in place. While it exists, the stack has **no**
> self-healing — that is exactly the window the backup uses on purpose.

## Observability

- **Log:** `{{ gitea_data_path }}/logs/stack-reconcile.log` (root, `0640`).
  Every pass appends timestamped lines; corrective actions and skips are all
  logged. The script self-caps the log at **1 MiB**
  (`stack_reconcile_log_max_bytes`, default `1048576`) — when exceeded it trims
  in place to the tail (it cannot `mv`/rotate the file because it is a Docker
  bind-mount target, which returns `EBUSY` on rename).
- **Discord alerts:** if `discord_webhook` is configured, each corrective action
  ("started orphaned container 'X'", "restarted 'gitea' …") posts one line. The
  webhook is a credential: it lives **only** in the `0600` root env-file
  (`reconcile.env`, templated `no_log: true`), sourced at runtime — never on the
  cron line, in the container `env:`, or in deploy logs. With no webhook, alerts
  are logged only.
- **Watchdog container logs:** `docker logs stack-reconcile` (json-file,
  `max-size 10m`, `max-file 3`).

## live-restore caveat (IMPORTANT)

On **Synology Docker 24.x**, a `dockerd` **SIGHUP reload may not flip
`LiveRestoreEnabled`**, even though the merged `dockerd.json` is correct. The
`container_manager_config` role therefore does **not** assert success: after the
SIGHUP it **verifies** at runtime with
`docker info --format '{{.LiveRestoreEnabled}}'` and, if live-restore is
not active, emits a distinct, un-missable **WARNING** line in the play recap
(it never fails the deploy).

Making live-restore actually active on those builds requires a one-time
`synopkg restart ContainerManager` — but that command **bounces every
container**. This is a chicken-and-egg: the very thing that activates the
protection is also the thing the protection guards against.

**Resolve it deliberately, in this exact order:**

1. **Deploy first.** Run `gitea-deploy.yml` so both roles are in place. This
   writes `dockerd.json` *and* brings up the `stack_reconcile` watchdog +
   host-cron. (Do **not** restart Container Manager before this — without the
   watchdog deployed, the bounce has nothing to self-heal it.)
2. **Check the recap.** If live-restore verified as active (`LiveRestoreEnabled
   = true`), you are done — SIGHUP worked on this build; skip the restart.
3. **Only if the WARNING fired**, run the one-time restart on the NAS:

   ```sh
   sudo synopkg restart ContainerManager
   ```

   This bounces all containers once, but it is safe now: `dockerd.json` is
   already correct (so live-restore comes up active), and the freshly-deployed
   `stack_reconcile` watchdog + `restart=always` self-heal anything that does
   not return on its own — in the correct dependency order
   (`tailscale-gitea → gitea-db → gitea`).
4. **Re-verify** after the bounce: `docker info --format
   '{{ "{{.LiveRestoreEnabled}}" }}'` should now print `true`. Subsequent daemon
   restarts will no longer stop containers.

The role never runs `synopkg` itself — the restart is a documented, operator-run
one-shot, and is unnecessary once live-restore is genuinely active.

## Manual recovery (the incident one-liner)

If you ever need to fix an orphaned-DB / crash-looping-Gitea situation by hand
(e.g. before reconcile is deployed, or while the maintenance lock is held), run
on the NAS:

```sh
/usr/local/bin/docker start gitea-db && /usr/local/bin/docker restart gitea
```

> The database takes **minutes** to pass its healthcheck — InnoDB crash recovery
> is slow on this box. Give `gitea-db` time to report `healthy` before expecting
> `gitea` to come up; restarting `gitea` too eagerly just resets its own
> healthcheck start window. Reconcile's dependency-gate step encodes exactly
> this: it waits for `gitea-db` healthy before restarting `gitea`.

If the tailscale sidecar is also down, start it first
(`/usr/local/bin/docker start tailscale-gitea`) so `gitea` has its network
namespace, then proceed as above.

## Related

- DR context and the manual fallback: `../../DR_RECOVERY_GUIDE.md`
- Runner host: `gitea-runner-host.md`
- The reconcile UI / tailnet URL referenced in alerts is
  `https://gitea.forest-draconis.ts.net`.
