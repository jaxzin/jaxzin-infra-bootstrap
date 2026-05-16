# Runbook: the Gitea Actions runner host

## Why this document exists

The rest of this repo provisions a Synology DSM NAS and is, by necessity,
tightly coupled to that host (DSM package manager, `/volume1` paths, the
DSM kernel's Docker quirks). **The Gitea Actions runner is deliberately
*not* coupled to any of that.** It was moved off the NAS onto a separate,
dedicated Linux host so the entire class of NAS/dind/Tailscale-sidecar
bugs (Gitea #25, `fallen-leaf/ansible-runner-image#15`) is removed by
architecture rather than patched.

The `gitea_runner` role therefore depends only on the **host contract**
below. If a host satisfies this contract, the role works on it; the role
must never grow a host-specific assumption again. This runbook is the
contract, and the regression lock-in for it lives in
`tests/check_docker_tasks.py` Check H and `tests/test-regression.yml`
CHECK 7.

## Host contract (the only things the role assumes)

1. **Linux with a running Docker Engine daemon.** Any distro. Not dind —
   the runner bind-mounts the host's `/var/run/docker.sock` and job
   containers run on the host's own Docker daemon.

2. **SSH reachable, key-based, as a `docker`-group user.** The deploy
   connects over SSH using a private key (its own CI secret — see
   "Provisioning" below). The login user must be a member of the
   `docker` group so the role can manage containers **without privilege
   escalation**: the runner play runs `become: false` and never needs
   sudo on the host. (If you genuinely cannot add the user to the
   `docker` group, the fallback is passwordless sudo + flipping the play
   to `become: true` — but the `docker`-group path is the supported one
   and needs no extra secret.)

3. **Host-level Tailscale, if tailnet access is required — and it is.**
   The runner reaches Gitea over the tailnet Serve URL and CI jobs `ssh`
   to tailnet hosts. The host must be a tailnet node (Tailscale running
   on the host, kernel mode). The runner gets tailnet reach *from the
   host*; this role deploys **no Tailscale sidecar** and uses plain
   `network_mode: bridge`. `ssh` to a tailnet host "just works" because
   the host routes `100.64.0.0/10` — no SOCKS5/ProxyCommand shim.

4. **A writable data directory.** Defaults to `~/.gitea-runner` of the
   deploy user (no root, no host-specific volume path). Override with the
   `GITEA_RUNNER_DATA_PATH` CI variable if the host has a dedicated mount.

5. **Outbound reachability to the Gitea instance URL** (the tailnet Serve
   URL, e.g. `https://gitea.<tailnet>`), for runner registration and job
   polling.

Anything else — OS family, package manager, kernel modules, filesystem
layout — is explicitly **out of contract**. The role must not look at it.

## Security trade-off (accept knowingly)

Socket-mount gives every CI job container root-equivalent authority over
the runner host's Docker daemon: a job can start privileged containers,
bind-mount the host filesystem, or stop the runner itself. This is
**acceptable here and only here** because this is a single-tenant homelab
where every workflow is trusted first-party IaC. It would be unacceptable
for multi-tenant or untrusted jobs. This is the deliberate price of
deleting the entire dind problem class; do not "fix" it by re-introducing
dind.

## Provisioning (CI secrets / variables)

The runner host is a *separate* host from the NAS with its *own*
credentials. Set these on the `jaxzin-infra-bootstrap` GitHub repo:

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_RUNNER_HOST` | Secret | Runner host address (topology — never in the repo). |
| `GITEA_RUNNER_SSH_USER` | Secret | SSH login user (must be in the `docker` group). |
| `GITEA_RUNNER_SSH_KEY` | Secret | Private SSH key for that user (separate from the NAS key). |
| `GITEA_RUNNER_DATA_PATH` | Variable | *(optional)* Override the `~/.gitea-runner` data dir. |
| `GITEA_RUNNER_IMAGE` | Variable | *(optional)* Override the act_runner image (default `gitea/act_runner:0.2.12`, **non-dind**). |
| `GITEA_RUNNER_NAME` | Variable | *(optional)* Display name (default `gitea-runner`). |

The bootstrap workflow stages `GITEA_RUNNER_SSH_KEY` to a `0600` file and
points the `[gitea_runner]` inventory group at it via
`ansible_ssh_private_key_file` (the NAS and the runner use different
keys).

## How it deploys (and when)

`playbooks/gitea-deploy.yml` is two plays:

- **Play 1 — `hosts: nas`, `become: true`:** Gitea server, its Tailscale
  sidecar (kernel mode for Serve), certbot, backups. Provisions the Gitea
  admin API token.
- **Play 2 — `hosts: gitea_runner`, `become: false`:** the `gitea_runner`
  role only. It borrows the admin token from Play 1 via `hostvars`
  (it never stores or mints that token — it uses it once to obtain its
  own runner registration token, talking to Gitea over the **tailnet**
  URL because the NAS-loopback API URL is meaningless on this host).

Because both plays run in the **same `ansible-playbook` invocation**, the
runner comes online *as part of the bootstrap deploy*. There is no
separate "deploy the runner" step and no Gitea-side trigger needed (which
also means there is no self-redeploy circularity: the runner is always
deployed *to* by the GitHub-side bootstrap, never by a job running on
itself).

Play 2 is skipped when the deploy is triggered from inside Gitea Actions
(`GITEA_ACTIONS=true`, the github→gitea mirror flow); only the GitHub
bootstrap deploy provisions the runner.

## First-boot / disaster recovery

See `DR_RECOVERY_GUIDE.md`. The short version: the runner is **not** a
separate manual seed. DR has exactly one manual seed (the self-hosted
GitHub runner). Running the bootstrap workflow stands up Gitea **and** the
runner together; the restore workflow then repopulates data. The runner
is online before any Gitea-side workflow needs it.

## Steady-state runner updates

Changing the runner image/labels/config is now an ordinary
`jaxzin-infra-bootstrap` change: edit the role, re-run the bootstrap
deploy. Updates flow through the GitHub-side pipeline over SSH — the
runner is never asked to redeploy itself.
