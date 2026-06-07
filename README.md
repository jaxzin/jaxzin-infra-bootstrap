# Bootstrap IaC for the Jackson Family Self-Hosted Infrastructure

Welcome to **my** bootstrap repository for The Jackson Family’s self-hosted infrastructure.
I use this repo to bootstrap and maintain the core foundation for my home-network Infrastructure as Code (IaC)—installing Gitea on a Synology
NAS, and restoring it’s backup from an off-site backup on Backblaze.

It is not monolithically responsible for _all_ (IaC) on my personal network. The Gitea recovery will restore additional
IaC CI/CD repos and workflows. This is meant to ensure I always have a reliable disaster-recovery path.

The only prerequisites to performing a disaster recovery are:
1. There is an available self-hosted GitHub runner on the home network (LAN + tailnet reachable), acting as the bootstrap controller. The Gitea Actions runner is deployed from there **over SSH** to a separate host set by the `GITEA_RUNNER_HOST` variable (seeded automatically by the `runner_host_seed` role in CI). See "Self-hosting a GitHub Runner" and...
2. that runner is attached to the mirror of this repo on Github.com and...
3. there is a Synology NAS available on the home network...
4. with the hostname defined in the Github repo’s variable `NAS_HOST` and...
5. the "Container Manager" package (aka Docker) is compatible with this NAS...
6. there is a latest backup of the Gitea data on Backblaze in the `B2_BUCKET_NAME`...
7. and the Tailscale auth key and tailnet domain are configured in the repo’s secrets/variables

---

## How I’ve Organized This Repo

```text
.gitea/
└── workflows/
    └── deploy.yml              # Daily deployments via Gitea Actions
.github/
├── workflows/
│   ├── bootstrap.yml           # GitHub-triggered DR bootstrap (recovery phase 1)
│   ├── common-bootstrap.yml    # Core provisioning steps (reusable)
│   ├── health-check.yml        # Daily dry run of DR bootstrap with Discord alert
│   ├── mirror-health.yml       # Daily mirror-health check with Discord alert
│   └── restore.yml             # GitHub-triggered DR restore (recovery phase 2, 🛑 DANGER)
playbooks/
├── roles/
│   ├── certbot/                # Let’s Encrypt certificate management
│   ├── gitea_backup/           # Gitea backup to Backblaze B2
│   ├── gitea_runner/           # Gitea Actions runner deployment
│   ├── gitea_server/           # Gitea server + MySQL deployment
│   └── tailscale_sidecar/      # Reusable Tailscale sidecar container
├── templates/
│   └── app.ini.j2              # Gitea configuration template
├── vars/
│   └── main.yml                # All playbook variables
├── gitea-deploy.yml            # Main deployment playbook
└── gitea-restore.yml           # Restore playbook
Makefile                        # Makefile for common tasks
```
---

## My Methodology

1. **Self-hosted Deployments**: Day-to-day modifications of my infrastructure are pushed to the self-hosted Gitea instance, including changes to the bootstrap infrastructure stored in this repository.
2. **Mirror & Monitor**: Every push to the self-hosted Gitea instance of this repo are immediately mirrored to the off-site GitHub mirror (where you are probably reading this). A daily job compares the self-hosted and cloud-hosted instance and notifies my personal Discord if they have drifted.
3. **DR Test**: Daily scheduled run on GitHub uses Ansible's check mode (with diffs) to validate playbooks. The results are posted to my personal Discord.
4. **On-Demand Recovery**: The DR workflow is manual and two-phased — first the bare infrastructure is bootstrapped, then a gated restore of the Gitea data from its latest cloud backup.

---

## Architecture Diagrams

### Container Networking (Gitea sidecar + remote runner)

```mermaid
flowchart TB
    subgraph Tailnet["Tailscale Tailnet"]
        TG_TS["tailscale-gitea<br/>(TS_SERVE: HTTPS → HTTP :3000)"]
        RunnerHost["GITEA_RUNNER_HOST<br/>(separate Linux host, host-level Tailscale)"]
    end
    subgraph DockerNet["gitea-net (Docker Bridge, on the NAS)"]
        TG_TS --- |"network_mode: container"| Gitea["gitea<br/>(HTTP :3000, SSH :22)"]
        DB["gitea-db<br/>(MySQL :3306)"]
    end
    subgraph RunnerBox["GITEA_RUNNER_HOST Docker daemon"]
        Runner["gitea-runner<br/>(act_runner: bridge + /var/run/docker.sock)"]
    end
    Gitea --> |"gitea-db:3306"| DB
    RunnerHost -. "runs the runner container" .-> Runner
    Runner --> |"https://gitea.tailnet (via host Tailscale)"| TG_TS
```

### Normal Operation (Happy Path)

```mermaid
flowchart TB
    subgraph Gitea_CI["Gitea (Self-Hosted)"]
        A[Push to Gitea Repo] --> B[Gitea Actions Trigger]
        B --> C[Gitea Runner Executes Ansible]
    end
    subgraph GitHub_CI["GitHub"]
        A --> E[Push Mirror to GitHub]
        T["Daily Trigger ⏰"]
        T --> F["Mirror Check"]
        F --> G["Discord Alert"]
        T --> H["Health Check (Dry Run)"]
        H --> G
    end
    C --> D[Synology NAS Configuration]
    D --> D1[Tailscale Sidecars]
    D --> D2[Gitea Server]
    D --> D3[Certbot]
    D --> D4[Gitea Runner]
```

### Failure & Recovery Mode

```mermaid
flowchart TB
    Start([Start Recovery from GitHub])
    Start -->|manual| Action_B[[Run 'Bootstrap' Action]]
    Action_B -->|manual| Action_R[[Run 'Restore Gitea Data' Action]]
    subgraph Restore[Restore Gitea Data]
        direction LR
        Approval[Wait for Approval]
        Approval -->|manual| R[GitHub Runner executes playbook]
        R --> M[SSH to Synology NAS]
        M --> N[Fetch & Restore Backup]
        N --> P[Services Back Online]
        P --> P0[Tailscale Sidecars]
        P --> P1[Gitea Server]
        P --> P2[Certbot]
        P --> P3[Gitea Runner]
    end
    Action_R -.- Restore
```

---

## Contributing

Details on how to contribute to this project, including how to set up a local development environment,
can be found in the [CONTRIBUTING.md](CONTRIBUTING.md) file.

---

## Tailscale Integration

Gitea is paired with a [Tailscale](https://tailscale.com) sidecar container that places it on your private Tailscale tailnet, providing secure, zero-config access from any device on your tailnet without exposing it to the public internet. The Gitea Actions runner is **not** a sidecar — it is deployed over SSH to a separate tailnet host (`GITEA_RUNNER_HOST`) and reaches Gitea through that host's own Tailscale (see [docs/runbooks/gitea-runner-host.md](docs/runbooks/gitea-runner-host.md)).

### How It Works

**Gitea sidecar (kernel-mode, namespace-shared):**
Gitea shares its network namespace with the `tailscale-gitea` sidecar via Docker's `network_mode: container:` option. The sidecar handles Tailscale connectivity, and [Tailscale Serve](https://tailscale.com/kb/1312/serve) terminates TLS for `https://gitea.<your-tailnet>` with a Tailscale-managed certificate, proxying to Gitea's HTTP port inside the shared namespace. Gitea itself runs plain HTTP internally; all HTTPS for the tailnet is handled by Tailscale Serve. Kernel mode is required here because Tailscale Serve depends on the kernel TUN device. See [docs/architecture/tailscale-sidecar-modes.md](docs/architecture/tailscale-sidecar-modes.md) for the deep dive.

The Gitea sidecar sits on `gitea-net`, which keeps MySQL (`gitea-db:3306`) reachable from Gitea while staying off the tailnet entirely.

**Gitea Actions runner (remote, host-tailnet, socket-mounted):**
The runner is **not** a sidecar. It is deployed over SSH to `GITEA_RUNNER_HOST` — a separate Linux host that already has Docker and is on the tailnet (seeded by the `runner_host_seed` role). The act_runner container runs with `network_mode: bridge` and bind-mounts the host's Docker socket, so job containers run on the host's own daemon and reach both the LAN and the tailnet directly through the host's networking — no dind, no SOCKS/HTTP proxy, no sidecar. Full contract: [docs/runbooks/gitea-runner-host.md](docs/runbooks/gitea-runner-host.md).

### Using This Repo as a Template

To set up Tailscale for your own fork:

1. Create a [Tailscale account](https://login.tailscale.com) and tailnet if you don't have one.
2. Generate a **reusable, non-ephemeral** auth key at Settings → Keys in the Tailscale admin console.
3. Set the `TS_AUTHKEY` **secret** and `TS_TAILNET` **variable** in your GitHub repo settings (see the table below).
4. Run the bootstrap workflow — Gitea will be available at `https://gitea.<your-tailnet>` from any tailnet device.
5. The runner is deployed to `GITEA_RUNNER_HOST` and reaches Gitea through that host's tailnet.

### Disabling Tailscale

Set `tailscale_enabled: false` in `playbooks/vars/main.yml` to skip all Tailscale tasks and use legacy direct Docker networking with Let's Encrypt HTTPS certificates instead.

### Synology NAS Note

If your Synology NAS also runs the Tailscale package at the OS level, the sidecar containers operate independently — they have their own Tailscale identities and state and do not depend on the host's Tailscale installation.

---

## What You Need to Do Once

### 1. Initial Repository Setup

This repository uses a protected GitHub Environment to provide a manual approval gate for the disaster recovery 
workflow. This prevents accidental restores. If you have forked this repository, you **must** configure this 
environment in your own repository settings.

**Steps:**

1.  Navigate to your forked repository on GitHub.
2.  Click on the **`Settings`** tab.
3.  In the left sidebar, click on **`Environments`**.
4.  Click the **`New environment`** button.
5.  For the name, enter `production-restore`.
6.  Click the **`Configure environment`** button.
7.  Under **Deployment protection rules**, check the box for **`Required reviewers`**.
8.  Add your own GitHub username (or a team you belong to) as a reviewer.
9.  Click **`Save protection rules`**.

### 2. GitHub Secrets and Variables

In GitHub (Settings → Secrets and variables → Actions → Secrets):

| Secret                  | Value/Purpose                                                          |
| ----------------------- | ---------------------------------------------------------------------- |
| `SSH_KEY`               | SSH private key for NAS                                                |
| `NAS_SSH_PASSWORD`      | NAS SSH user password                                                  |
| `NAS_SSH_USER`          | NAS SSH user (topology)                                                |
| `NAS_HOST`              | FQDN/IP of NAS (topology)                                              |
| `LAN_DNS`               | DNS server for container resolution of `NAS_HOST` (topology)           |
| `B2_APPLICATION_KEY`    | Backblaze B2 Application Key                                           |
| `B2_APPLICATION_KEY_ID` | Backblaze B2 Application Key ID                                        |
| `B2_BUCKET_NAME`        | Backblaze B2 Bucket Name                                               |
| `DISCORD_WEBHOOK`       | Discord webhook for alerts                                             |
| `DNSIMPLE_OAUTH_TOKEN`  | DNSimple OAuth Token                                                   |
| `GITEA_ADMIN_PASSWORD`  | Gitea Admin User Password                                              |
| `GITEA_DB_PASSWORD`     | Gitea Database Password                                                |
| `GITEA_LAN_HOST`        | LAN-facing host/IP for Gitea (topology). On Gitea side, store under the alias `MYGITEA_LAN_HOST` — the `GITEA_*` prefix is reserved by Gitea Actions. |
| `GITEA_LAN_SSH_PORT`    | LAN port for Gitea SSH (defaults to `2222` if unset). On Gitea side, store under the alias `MYGITEA_LAN_SSH_PORT` — same reservation. |
| `LAN_DOMAIN_SUFFIX`     | LAN DNS suffix used for `NO_PROXY` exemption inside the Gitea Actions runner so LAN hostnames bypass the userspace tailnet proxy (topology). Include the leading dot, e.g. `.lan.example.com`. |
| `TS_AUTHKEY`            | Tailscale auth key (reusable, non-ephemeral)                           |
| `TS_TAILNET`            | Tailscale tailnet domain, e.g. `your-tailnet.ts.net` (topology secret) |

> Topology values (`NAS_HOST`, `NAS_SSH_USER`, `LAN_DNS`, `TS_TAILNET`, `GITEA_LAN_HOST`, `LAN_DOMAIN_SUFFIX`) are stored as Secrets — not Variables — because Actions Variables are not redacted in workflow logs and this repo is mirrored to a public GitHub presence. See issue #6.
>
> Gitea Actions reserves the `GITEA_*` prefix for system context variables. Repo-level Secrets in that namespace are rejected by the API. Plan #1's new Secrets (`GITEA_LAN_HOST`, `GITEA_LAN_SSH_PORT`) use the existing repo convention: store under the `MYGITEA_*` alias on Gitea, keep `GITEA_*` on GitHub, and the workflow falls back across both via `${{ secrets.GITEA_X || secrets.MYGITEA_X }}` (mirrors the existing `GITEA_ADMIN_USERNAME` / `MYGITEA_ADMIN_USERNAME` pattern).

In GitHub (Settings → Secrets and variables → Actions → Variables):

| Variable              | Value/Purpose                                      |
| --------------------- | -------------------------------------------------- |
| `CERTBOT_EMAIL`       | Certbot Email Address                              |
| `GITEA_ADMIN_USERNAME`| Gitea Admin Username                               |
| `GITEA_ADMIN_EMAIL`   | Gitea Admin Email                                  |

### 3. Self-hosting a GitHub Runner

> ## ℹ️ The Gitea runner host is remote and swappable
>
> The Gitea Actions runner is deployed **over SSH** to `GITEA_RUNNER_HOST`.
> The controller (the home-network GitHub runner) and the target are
> **different machines** — no same-box requirement. The target only needs
> SSH + a sudo user + a Docker-capable Linux host on the tailnet; the
> `runner_host_seed` role provisions the rest.
>
> Full contract: [docs/runbooks/gitea-runner-host.md](docs/runbooks/gitea-runner-host.md).

A self-hosted GitHub runner is required to execute the disaster recovery workflows from GitHub. It must be on a Linux 
machine with Docker installed (the bootstrap process uses a container, unsupported by GitHub runners on macOS/Windows). 
Tested on Ubuntu 24.

You can set up the runner with the provided `install-runner.sh` script. It will prompt for a runner name and a GitHub 
registration token.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jaxzin/jaxzin-infra-bootstrap/main/scripts/install-runner.sh)"
```

### 4. Self-hosting the Bootstrap repository
After running the Bootstrap setup for the first time, Gitea will be running.
To then begin self-hosting the bootstrap CI/CD, you can follow these steps:
#### 4.1. **Mirror the Repository to Gitea**:
   - Go to your Gitea instance.
   - Select **New Migration**.
   - Select **GitHub**.
   - Enter the URL of this GitHub repository.
   - Do not choose "This repository will be a mirror", we will connect it as a push mirror later.
   - Click **Migrate Repository**.
#### 4.2. **Set Up Push Mirror**:
    - Go to the newly created repository in Gitea.
    - Click on **Settings** → **Mirroring**.
    - Under **Push Mirror**, enter the URL of this GitHub repository.
    - Enter your GitHub username and a personal access token with `repo` and `workflow` scope. `workflow` scope is needed to allow the push mirror to push up workflow file changes.
    - Click **Add Mirror**.
#### 4.3. **Configure Gitea Secrets and Variables**:
   - Go to **Settings** → **Actions** in Gitea.
   - Add the same secrets and variables as you did for GitHub (see above), including
     `TS_AUTHKEY` and `TS_TAILNET`.
---

## Workflow Details

### Gitea Only
#### Daily Gitea Workflow (`.gitea/workflows/deploy.yml`)

Use this workflow to deploy changes to your Gitea instance daily.

* Runs on push.

### GitHub Only
#### Bootstrap (`.github/workflows/bootstrap.yml`)

Use this workflow to bootstrap the disaster recovery process.

* Manually triggered.

#### Restore (`.github/workflows/restore.yml`)

* Manually triggered.
* Gated by the `production-restore` environment to prevent accidental restores.

### Health Check (`.github/workflows/health-check.yml`)

* Runs daily.
* Notifies Discord on success or failure.

### Mirror-Health Check (`.github/workflows/mirror-health.yml`)

* Runs daily.
* Checks freshness of mirror.
* Notifies Discord on success or failure.

### Gitea Runner vs GitHub Runner

This bootstrap process also installs and configures a Gitea runner — **on the same dedicated Linux host as the GitHub
self-hosted runner, NOT on the Synology NAS** (see "Self-hosting a GitHub Runner" above and
[docs/runbooks/gitea-runner-host.md](docs/runbooks/gitea-runner-host.md)). That runner executes the CI/CD workflows for
the majority of my home network's IaC; the GitHub runner is used for disaster-recovery workflows only. The Gitea server
and Certbot run as Docker containers on the NAS; the Gitea runner runs as a socket-mounted container on its own host.

---

## Performing Disaster Recovery from GitHub

1. Provision replacement NAS with hostname matching the `NAS_HOST` variable.
2. Ensure off-NAS GitHub runner can SSH in.
3. On GitHub, run Actions → Bootstrap; then Actions → Restore Gitea Data.
4. Approve if safe.
5. Restore then automatically runs, unarchiving backup and restarting services.

> **Note:** The bootstrap playbook deploys the Tailscale sidecar containers before Gitea and the runner. After a restore, the sidecars must be running before Gitea can start because Gitea depends on the sidecar's network namespace (`network_mode: container:`). The playbook handles this ordering automatically.

---

## Ongoing Maintenance

* **Monthly DR tests** validate playbooks.
* **Daily mirror-health** alerts keep you aware.
* **The most critical IaC** lives on Gitea _and_ GitHub, so hardware failures don’t lose automation.

Happy automating The Jackson Family way! 🚀

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
