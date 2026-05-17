# Runbook: the Gitea Actions runner host

## Why this document exists

The rest of this repo provisions a Synology DSM NAS and is, by necessity,
tightly coupled to that host. **The Gitea Actions runner is deliberately
*not*.** It was moved off the NAS onto a separate, dedicated Linux host so
the entire class of NAS/dind/Tailscale-sidecar bugs (Gitea #25,
`fallen-leaf/ansible-runner-image#15`) is removed by architecture rather
than patched.

The `gitea_runner` role depends only on the **host contract** below. If a
host satisfies it, the role works; the role must never grow a
host-specific assumption again. Regression lock-in:
`tests/check_docker_tasks.py` Check H, `tests/test-regression.yml`
CHECK 7 + CHECK 8.

---

## ⚠️ PREREQUISITES — read first

These live **outside** the runner host, are **not** checked by any script,
and the whole design fails silently without them:

1. **The machine that runs the bootstrap workflow (the self-hosted
   GitHub Actions runner) MUST itself be on the tailnet** and able to
   reach the runner host over **Tailscale SSH**. Ansible Play 2 connects
   to the runner host *as* this CI environment — if it has no tailnet
   path, the deploy cannot connect. There is no SSH-key fallback by
   design.

2. **The tailnet ACL policy MUST permit that CI identity to
   Tailscale-SSH into the runner host as the deploy user.** `tailscale up
   --ssh` on the host only *exposes* SSH; the tailnet `ssh` ACL rule is
   what *authorizes* the CI→host session. Without the ACL rule the
   connection is refused.

If either is missing, fix it before running the bootstrap workflow.

---

## Host contract (the only things the role assumes)

1. **Linux with a running Docker Engine daemon.** Any distro. Not dind —
   the runner bind-mounts the host's `/var/run/docker.sock`; job
   containers run on the host's own Docker daemon.

2. **A deploy user in the `docker` group.** Ansible Play 2 runs
   `become: false`: no sudo on this host. (`bootstrap-runner.sh` creates
   the user and adds it to `docker`.)

3. **Host-level Tailscale, with Tailscale SSH enabled.** The runner
   reaches Gitea over the tailnet Serve URL and CI jobs `ssh` to tailnet
   hosts; the host gets tailnet reach itself (kernel mode). The role
   deploys **no Tailscale sidecar** and uses plain `network_mode:
   bridge`. The Ansible connection channel is **Tailscale SSH** — there
   is no managed SSH keypair anywhere in this design.

4. **A writable data directory.** Defaults to `~/.gitea-runner` of the
   deploy user (no root, no host-specific volume path). Override with the
   `GITEA_RUNNER_DATA_PATH` CI variable.

5. **Outbound reachability to the Gitea instance URL** (the tailnet Serve
   URL), for runner registration and job polling.

Anything else — OS family, package manager, kernel modules, filesystem
layout — is **out of contract**. The role must not look at it.

## The seed: `bootstrap-runner.sh`

`bootstrap-runner.sh` (repo root) is the **single, documented manual
seed** for this host — the irreducible "first trust" step. It is
idempotent; it is also the disaster-recovery step for the runner host.

```
sudo ./bootstrap-runner.sh
# optional: sudo GITEA_RUNNER_DEPLOY_USER=ci ./bootstrap-runner.sh
```

It installs Docker + Tailscale, creates the deploy user in the `docker`
group, runs **interactive** `tailscale up --ssh` (operator authenticates
in a browser — **no `TS_AUTHKEY`, no SSH key**), and prints the values to
put in CI. It stores no secrets.

## Security trade-off (accept knowingly)

Socket-mount gives every CI job container root-equivalent authority over
the runner host's Docker daemon. This is acceptable **here and only
here** — a single-tenant homelab where every workflow is trusted
first-party IaC. It is the deliberate price of deleting the entire dind
problem class; do not "fix" it by re-introducing dind.

## CI configuration

After `bootstrap-runner.sh`, set on the `jaxzin-infra-bootstrap` GitHub
repo:

| Name | Kind | Purpose |
|---|---|---|
| `GITEA_RUNNER_HOST` | **Secret** | The host's tailnet MagicDNS name (Secret because it contains the tailnet). |
| `GITEA_RUNNER_SSH_USER` | Variable | The deploy user (default `gitea-runner`). |
| `GITEA_RUNNER_DATA_PATH` | Variable | *(optional)* Override `~/.gitea-runner`. |
| `GITEA_RUNNER_IMAGE` | Variable | *(optional)* Override the act_runner image (default `gitea/act_runner:0.2.12`, **non-dind**). |
| `GITEA_RUNNER_NAME` | Variable | *(optional)* Display name (default `gitea-runner`). |

There is intentionally **no `GITEA_RUNNER_SSH_KEY`** — the channel is
Tailscale SSH (see prerequisites).

## How it deploys (and when)

`playbooks/gitea-deploy.yml` is two plays:

- **Play 1 — `hosts: nas`, `become: true`:** Gitea server + its Tailscale
  sidecar (kernel mode for Serve), certbot, backups. Provisions the Gitea
  admin API token.
- **Play 2 — `hosts: gitea_runner`, `become: false`:** the `gitea_runner`
  role only, connecting over **Tailscale SSH**. It borrows the admin
  token from Play 1 via `hostvars` (never stores/mints it — uses it once
  to obtain the runner registration token, talking to Gitea over the
  **tailnet** URL).

Both plays run in the **same `ansible-playbook` invocation**, so the
runner comes online *as part of bootstrap*. There is no separate "deploy
the runner" step and no Gitea-side trigger — hence no self-redeploy
circularity (the runner is always deployed *to* by the GitHub-side
bootstrap over Tailscale SSH, never by a job on itself).

Play 2 is skipped when triggered from inside Gitea Actions
(`GITEA_ACTIONS=true`, the github→gitea mirror flow).

## First-boot / disaster recovery

DR has exactly **one** manual seed: the self-hosted GitHub runner (the
root of trust). For the runner host specifically the seed is
`bootstrap-runner.sh` run once. The runner is **not** a second
independent seed — after the host seed, it is Play 2 of the ordinary
bootstrap deploy. See `DR_RECOVERY_GUIDE.md`.

## Steady-state runner updates

Changing the runner image/labels/config is an ordinary
`jaxzin-infra-bootstrap` change: edit the role, re-run the bootstrap
deploy. Updates flow GitHub-side over Tailscale SSH — the runner is never
asked to redeploy itself.
