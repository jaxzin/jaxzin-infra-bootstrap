# Runbook: the Gitea Actions runner host

## What this is

The Gitea Actions runner is deployed **opportunistically over SSH** to any
Linux host that has Docker and is on the tailnet. The host is chosen by the
`GITEA_RUNNER_HOST` CI variable and is **swappable** — nothing about the
design is specific to any particular host. (Do NOT record the concrete host
or its IP in this public repo; refer to it only as `GITEA_RUNNER_HOST`.)

The deploy controller (the home-network GitHub self-hosted runner) and the
runner target are **different machines**, connected over SSH.

## Target-host contract (the only things assumed)

1. Reachable over **SSH** from the controller, with a sudo-capable user
   (`GITEA_RUNNER_SSH_USER`) and the `GITEA_RUNNER_SSH_KEY` authorized. Play 2
   runs `become: true` with key auth and **no** become password, so that user
   needs **passwordless sudo** — the SD-image bake or the one-time seed below
   installs it (a `/etc/sudoers.d/gitea-runner` NOPASSWD drop-in). Without it
   Play 2 fails on its first escalation with `Missing sudo password`.
2. Reachable **before** it is on the tailnet (the seed joins the tailnet),
   so `GITEA_RUNNER_HOST` must be LAN-resolvable at seed time.
3. A systemd Linux host where Docker can be installed.

Everything else is provided by the deploy:

- **`runner_host_seed` role** installs Docker + the Docker SDK for Python,
  joins the tailnet via the `TS_AUTHKEY` secret (with **`--accept-dns=false`**
  by default — see "Shared-host DNS" below), and creates the data dir. The
  authkey is only required when the host is not already on the tailnet.
- **`gitea_runner` role** is a pure consumer: it asserts Docker + tailnet
  are present (fails fast otherwise), then deploys + registers the
  socket-mounted act_runner container with an arch-derived label.

## Shared-host DNS (why `--accept-dns=false`)

The runner host may be **shared** with other services (e.g. a host that also
runs a sensor/weather bridge resolving LAN names like `*.iot.<lan-domain>`).
If Tailscale joins with `--accept-dns=true`, `tailscaled` **rewrites the
host's `/etc/resolv.conf`** to MagicDNS and the host can lose resolution of
its own LAN names — breaking those co-located services.

So `runner_host_seed` joins with **`--accept-dns=false`** (var
`runner_host_seed_accept_dns`, default `false`), leaving the host resolver
untouched. The runner **container** then can't use MagicDNS to find
`gitea.<tailnet>`, so the deploy **pins it**: Play 1 captures Gitea's tailnet
IP (`tailscale ip -4` on the Gitea sidecar) and passes it as
`gitea_runner_gitea_tailnet_ip`; the `gitea_runner` role adds a
`gitea.<tailnet> -> <ip>` entry to the act_runner container's `/etc/hosts`.
TLS still validates because the connection uses the hostname (Tailscale Serve
cert matches).

Set `runner_host_seed_accept_dns: true` only on a **dedicated** runner host
whose tailnet split-DNS already covers its LAN domains (then the pin is
unnecessary, though harmless).

## Trust anchor: the runner SSH key + passwordless sudo

Play 2 logs in as the `gitea-runner` account with the `GITEA_RUNNER_SSH_KEY`
private key and runs `become: true` with **no** become password, so the target
must already have (a) the dedicated runner **public** key authorized for that
account and (b) **passwordless sudo** for it. That is the one bit of trust a
host can't install over the very SSH+sudo it grants (circular), so it must be
placed out-of-band. Two paths install the identical anchor.

**The dedicated keypair (one time ever / on rotation).** `gitea-runner.pub` is
already committed at `playbooks/files/gitea-runner.pub`. To (re)generate:

    ssh-keygen -t ed25519 -f gitea-runner -C gitea-runner -N ''
    # gitea-runner.pub  -> commit to playbooks/files/gitea-runner.pub
    # gitea-runner (private) -> paste into the GITEA_RUNNER_SSH_KEY CI secret

### Primary: bake it into the SD image (new / replacement Pi)

For a Raspberry Pi (microSD), provisioning **is** the SD flash, so the anchor
rides along with it — no separate seed run, no interactive sudo password, and
the Pi boots CI-ready. `provisioning/runner-host/firstrun.sh` creates the
`gitea-runner` account, authorizes the committed key, installs the
visudo-validated NOPASSWD drop-in, and enables SSH at first boot, then
self-cleans.

1. Flash Raspberry Pi OS (Bookworm) to the card.
2. Mount the card's boot partition (`bootfs`) and copy the script there
   (macOS path shown):

       cp provisioning/runner-host/firstrun.sh /Volumes/bootfs/firstrun.sh

3. Append the first-boot hook to `cmdline.txt` on that partition — one line, no
   newline (Bookworm path shown; pre-Bookworm images use `/boot/firstrun.sh`):

       systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target

4. Set the hostname so `GITEA_RUNNER_HOST` resolves on the LAN (via the Imager,
   `raspi-config`, or DHCP/mDNS — host-specific, not baked in). Set the
   `GITEA_RUNNER_SSH_USER` CI variable to `gitea-runner` to match the account
   this script creates.
5. Boot the Pi. It provisions on first boot, self-cleans, and reboots ready —
   the GitHub bootstrap can then run Play 2 with no manual touch on the host.

The embedded public key is locked to `playbooks/files/gitea-runner.pub` by
Check L in `tests/check_docker_tasks.py`, so the baked anchor can't drift from
the key CI authenticates with.

### Reconcile / rotate on a running host (`seed-runner-ssh.yml`)

For a Pi that is ALREADY running (to rotate the key, or to seed a host you
didn't flash yourself), install the same anchor over SSH:

    ansible-playbook seed-runner-ssh.yml -i 'GITEA_RUNNER_HOST,' -u gitea-runner -K

Pass `-K` (`--ask-become-pass`) the first time if passwordless sudo isn't yet
in place (e.g. a host that predates the baked image); the sudoers task needs the
account's sudo password once. The drop-in is `visudo`-validated, so a malformed
entry can never lock sudo out. The playbook is idempotent — re-run any time.
(You can't install the key over the key it installs, so run it using existing
access to the host.)

## CI configuration

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_RUNNER_HOST` | Secret | The target host (LAN-resolvable for pre-tailnet seeding). |
| `GITEA_RUNNER_SSH_USER` | Variable | Sudo-capable SSH user on the target; set to `gitea-runner` (the account the SD bake / seed creates with passwordless sudo). |
| `GITEA_RUNNER_SSH_KEY` | Secret | Private key authorized on the target. |
| `TS_AUTHKEY` | Secret | Reused to join the target to the tailnet. |
| `GITEA_RUNNER_IMAGE` / `_NAME` / `_DATA_PATH` | Variable | Optional overrides (see role defaults). |

## How it deploys (and when)

`playbooks/gitea-deploy.yml` is two plays in one invocation:

- **Play 1 — `hosts: nas`, `become: true`:** Gitea server + sidecar; mints
  the runner registration token on the NAS loopback admin API.
- **Play 2 — `hosts: gitea_runner`, SSH, `become: true`:** seeds the host
  (`runner_host_seed`) then deploys the runner (`gitea_runner`), borrowing
  Play 1's token via hostvars. Skipped under `GITEA_ACTIONS=true`.

## Disaster recovery / wave ordering

**Manual prerequisite:** a GitHub self-hosted runner on the home network
(LAN + tailnet reachable) — the bootstrap entry point.

1. **Wave 1 (`jaxzin-infra-bootstrap`, GitHub CI):** bootstrap -> Gitea on the
   NAS; restore -> Gitea data; seed `GITEA_RUNNER_HOST` (Docker + tailnet);
   deploy the runner -> Gitea CI is live.
2. **Wave 2 (Gitea CI):** the rest of the fleet (apps deployed via Gitea CI).

Acyclic because seeding + runner deploy run in the GitHub layer and need no
gitea runner; the gitea runner is only required from Wave 2 on.

## Security trade-off (accept knowingly)

The act_runner is **socket-mounted**: every CI job container has
root-equivalent authority over the target's Docker daemon (the deliberate
price of deleting dind). When the runner shares a host with another service,
treat the box as single-tenant-trusted; keep runner `capacity: 1`.

The deploy account also has **passwordless sudo** (`NOPASSWD: ALL`, seeded
above). Accept knowingly: on a socket-mounted host the runner already holds
root-equivalent authority via the Docker socket, so NOPASSWD grants nothing it
couldn't already obtain — it just lets the unattended SSH deploy escalate
without a stored sudo password. The grant is scoped to the dedicated deploy
account, which is reachable only with the `GITEA_RUNNER_SSH_KEY` private key.
