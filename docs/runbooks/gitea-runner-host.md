# Runbook: the Gitea Actions runner host

## Why this document exists

The rest of this repo provisions a Synology DSM NAS and is, by necessity,
tightly coupled to that host. **The Gitea Actions runner is deliberately
*not*.** It was moved off the NAS so the entire class of NAS/dind/
Tailscale-sidecar bugs (Gitea #25, `fallen-leaf/ansible-runner-image#15`)
is removed by architecture rather than patched.

The `gitea_runner` role depends only on the **host contract** below.
Regression lock-in: `tests/check_docker_tasks.py` Check H,
`tests/test-regression.yml` CHECK 7 + CHECK 8.

---

## ⚠️ PREREQUISITES — read first

The whole design fails (silently or confusingly) if these are wrong. None
are enforced by a script — the docs are the only guard:

1. **The self-hosted GitHub Actions runner MUST be installed on the SAME
   machine you want the Gitea runner on.** The bootstrap deploy connects
   to the Gitea runner host with a **local connection** (Play 2 is
   `connection: local`) — there is no SSH, no Tailscale SSH, no key
   between them *because they are the same box*. Register the GitHub
   self-hosted runner on that host.

2. **Do NOT register the GitHub self-hosted runner on your laptop/Mac**
   "just to get things up quickly." It must be Linux (it runs a Linux
   job container), and co-located with the Gitea runner. A laptop runner
   breaks the local-connection topology and won't have the host Docker /
   data-dir mounts the deploy needs.

3. **That machine must NOT be the Synology DSM/NAS.** The NAS is Play 1's
   target and is deliberately decoupled from the runner; running the
   runner on the DSM reintroduces the whole NAS/dind problem class this
   work removed.

4. **That machine must be a tailnet node (kernel-mode Tailscale).** This
   is so the runner *container* can reach Gitea over the tailnet and CI
   jobs can `ssh` tailnet hosts. Plain tailnet membership only — **not**
   Tailscale SSH; nothing in this design uses Tailscale SSH or a tailnet
   `ssh` ACL.

In short: **the GitHub runner host == the Gitea runner host == a
tailnet-joined Linux box that is not the DSM and not your laptop.**

---

## Host contract (the only things the role assumes)

1. **Linux with a running Docker Engine daemon.** Not dind — the runner
   bind-mounts the host's `/var/run/docker.sock`; job containers run on
   the host's own Docker daemon.

2. **A deploy user in the `docker` group.** (`bootstrap-runner.sh`
   creates the user and adds it.)

3. **A tailnet node (kernel mode).** For the runner container's egress to
   Gitea/tailnet — not for the Ansible connection (that is local).

4. **A fixed, writable data directory** (default `/opt/gitea-runner`).
   This exact host path is bind-mounted into the CI job *and* into the
   runner container, so it must be coherent on the host —
   `bootstrap-runner.sh` provisions it. Override via
   `GITEA_RUNNER_DATA_PATH` (then update the CI job mount to match).

5. **Outbound reachability to the Gitea tailnet URL**, for runner
   registration and job polling.

Anything else — OS family, package manager, kernel modules — is **out of
contract**.

## The seed: `bootstrap-runner.sh`

`bootstrap-runner.sh` (repo root) is the **single documented manual
seed** for this host. Idempotent; also the runner-host DR step.

```
sudo ./bootstrap-runner.sh
# optional: sudo GITEA_RUNNER_DEPLOY_USER=ci ./bootstrap-runner.sh
# optional: sudo GITEA_RUNNER_DATA_PATH=/srv/gitea-runner ./bootstrap-runner.sh
```

It installs Docker + Tailscale, creates the deploy user in the `docker`
group, ensures the host is on the tailnet (interactive `tailscale up` —
no `--ssh`, no `--authkey` — only if not already joined; it touches
nothing on an already-joined node), and creates the data dir. It stores
no secrets and never enables Tailscale SSH.

## Security trade-off (accept knowingly)

Two things give elevated authority on this one machine, both accepted for
a single-tenant homelab of trusted first-party IaC:

- **Socket-mount:** every CI job container has root-equivalent authority
  over this host's Docker daemon (the deliberate price of deleting dind).
- **CI gets the host Docker socket + data dir:** because the bootstrap
  controller and the runner are the same box, the CI job bind-mounts
  `/var/run/docker.sock` and `/opt/gitea-runner` from the host.

Do not "fix" the first by re-introducing dind.

## CI configuration

After `bootstrap-runner.sh`:

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_RUNNER_HOST` | Secret | Only a human-readable inventory label now (the tailnet name). Kept a Secret as it contains the tailnet. |
| `GITEA_RUNNER_DATA_PATH` | Variable | *(optional)* Override `/opt/gitea-runner` (also change the CI job mount + re-run the seed). |
| `GITEA_RUNNER_IMAGE` | Variable | *(optional)* Override the act_runner image (default `gitea/act_runner:0.6.1`, **non-dind** — pinned for DR reproducibility; bump deliberately). |
| `GITEA_RUNNER_NAME` | Variable | *(optional)* Display name (default `gitea-runner`). |

There is intentionally **no `GITEA_RUNNER_SSH_KEY`** and the connection is
**local**, not SSH/Tailscale SSH. `GITEA_RUNNER_SSH_USER`, if you set it
earlier, is now unused and can be deleted.

## How it deploys (and when)

`playbooks/gitea-deploy.yml` is two plays in one invocation:

- **Play 1 — `hosts: nas`, `become: true`:** Gitea server + its Tailscale
  sidecar (kernel mode for Serve), certbot, backups. Provisions the Gitea
  admin API token.
- **Play 2 — `hosts: gitea_runner`, `connection: local`:** the
  `gitea_runner` role only, running *in the CI job container on this same
  host*, driving the host Docker daemon via the bind-mounted socket. It
  borrows the admin token from Play 1 via `hostvars` (never stores/mints
  it — uses it once to obtain the runner registration token over the
  tailnet Gitea URL).

The runner comes online *as part of bootstrap*. No separate "deploy the
runner" step, no Gitea-side trigger — hence no self-redeploy circularity
(the runner is deployed *to* by the bootstrap run, never by a job on
itself). Play 2 is skipped when triggered from inside Gitea Actions
(`GITEA_ACTIONS=true`, the github→gitea mirror flow).

## First-boot / disaster recovery

DR has exactly **one** manual seed: the self-hosted GitHub runner host
(installed per the prerequisites), bootstrapped once with
`bootstrap-runner.sh`. The Gitea runner is **not** a second independent
seed — after the host seed it is just Play 2 of the ordinary bootstrap
deploy. See `DR_RECOVERY_GUIDE.md`.

## Steady-state runner updates

Changing the runner image/labels/config is an ordinary
`jaxzin-infra-bootstrap` change: edit the role, re-run the bootstrap
deploy. Updates flow through the bootstrap run on this host — the runner
is never asked to redeploy itself.
