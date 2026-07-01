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

1. Reachable over **SSH** from the controller, with the `GITEA_RUNNER_SSH_KEY`
   authorized for `GITEA_RUNNER_SSH_USER`, and that user must have
   **passwordless sudo** (`NOPASSWD`). Play 2 runs `become: true`
   non-interactively over SSH and supplies **no** sudo password — the Raspberry
   Pi default `pi` user already has `NOPASSWD: ALL`. (Do NOT wire a become
   password: feeding one into a NOPASSWD sudo flow makes Ansible fail with
   "Incorrect sudo password".) Confirm with
   `sudo -k; sudo -n true && echo PASSWORDLESS-SUDO`.
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

## SSH access (one-time seed, IaC)

The runner deploy logs in as a sudo-capable account (`GITEA_RUNNER_SSH_USER`).
Authorize a dedicated runner keypair once (and on DR):

    ssh-keygen -t ed25519 -f gitea-runner -C gitea-runner -N ''
    # gitea-runner.pub  -> commit to playbooks/files/gitea-runner.pub
    # gitea-runner (private) -> paste into the GITEA_RUNNER_SSH_KEY CI secret
    ansible-playbook seed-runner-ssh.yml -i 'GITEA_RUNNER_HOST,' -u <GITEA_RUNNER_SSH_USER>

`seed-runner-ssh.yml` is idempotent — re-run any time / on DR. Install it
using whatever existing SSH access you already have to the host (you cannot
install the key over the key it installs).

## CI configuration

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_RUNNER_HOST` | Secret | The target host (LAN-resolvable for pre-tailnet seeding). |
| `GITEA_RUNNER_SSH_USER` | Variable | Sudo-capable SSH user on the target. |
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
