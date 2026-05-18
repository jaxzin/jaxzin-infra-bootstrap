# Disaster Recovery Guide

This guide provides instructions for setting up and recovering from each of the three disaster recovery tiers.

## Tier 1: Btrfs Snapshots (Local Fast Recovery)

(Content unchanged)

## Tier 2: Hyper Backup (Remote/Offsite Protection)

(Content unchanged)

## Tier 3: Gitea Archive (Portable Disaster Recovery)

This tier uses the application-native backup and restore functionality of Gitea, creating a portable archive that can be restored to any new host.

### Automated Backup Setup

The `gitea-deploy.yml` playbook automatically **configures and enables** a daily, automated backup. It deploys a script to the NAS and schedules it to run daily via a cron job. This script stops Gitea, creates a full dump, uploads it to Backblaze B2, and restarts Gitea. The playbook also deploys Certbot for SSL certificate management.

`gitea-deploy.yml` is **two plays in one invocation**: Play 1 provisions the Gitea server on the NAS; **Play 2 provisions the Gitea Actions runner on the same machine as the GitHub self-hosted runner** (`connection: local` — see `docs/runbooks/gitea-runner-host.md`). Running the bootstrap workflow therefore brings the runner online *as part of bootstrap* — there is **no separate "deploy the runner" step** and no Gitea-side trigger to fire.

### The manual seed

Disaster recovery has **one** irreducible, documented manual seed (a committed, version-controlled procedure — not improvisation): a self-hosted **GitHub Actions runner** host that is **also** the Gitea runner host, seeded once with `sudo ./bootstrap-runner.sh`.

> **PREREQ (easy to miss — no script enforces it):** that host must be a **dedicated tailnet-joined Linux box that is NOT the NAS and NOT a laptop/Mac**. The GitHub runner and the Gitea runner are the *same* machine; Play 2 connects locally (no SSH, no Tailscale SSH, no key). `bootstrap-runner.sh` installs Docker, creates the `docker`-group deploy user, ensures the host is on the tailnet (plain `tailscale up`, no `--ssh`), and creates the data dir. Full detail: `docs/runbooks/gitea-runner-host.md`.

### Recovery Method 1: Automated GitHub Action (Recommended)

This is the primary and recommended method for disaster recovery. It uses GitHub Actions to ensure a repeatable and reliable execution.

**Prerequisites:**

*   The self-hosted GitHub Actions runner online, on the dedicated tailnet-joined Linux host (NOT the NAS, NOT a laptop), seeded once with `sudo ./bootstrap-runner.sh` — the single manual seed above. This same host runs the Gitea runner. **No SSH key, no Tailscale SSH** — Play 2 connects locally. Full contract: `docs/runbooks/gitea-runner-host.md`.

**Recovery Steps:**

1.  **Ensure the GitHub Runner is Available:** Make sure at least one self-hosted GitHub Actions runner is online and available on your local network.
2.  **Run the Bootstrap Workflow:** Manually trigger the `Bootstrap` workflow from the GitHub Actions tab. This runs `gitea-deploy.yml`: Play 1 provisions Gitea on the new NAS; **Play 2 brings the Gitea Actions runner online on its dedicated host** (it borrows the freshly-minted admin token from Play 1 to register itself). No further step is needed to get CI working.
3.  **Run the Restore Workflow:** Once the bootstrap is complete, manually trigger the `Restore Gitea Data` workflow. This requires a manual approval step before it runs the `gitea-restore.yml` playbook to populate the new instance with your backed-up data. The runner is already online from step 2, so restored repos' workflows can run immediately.

### Recovery Method 2: Manual Fallback

This method should only be used if GitHub Actions is unavailable or the automated workflow fails.

**Prerequisites:**

*   A new NAS host with Ansible and Docker installed.
*   The runner host seeded with `sudo ./bootstrap-runner.sh` (see `docs/runbooks/gitea-runner-host.md`). Run the manual recovery **from that same host** — Play 2 uses a local connection, so the control machine and the runner host must be the same box.
*   A local checkout of this repository.
*   A valid Ansible inventory file defining a `[nas]` group and a `[gitea_runner]` group, the latter as `<label> ansible_connection=local` (no SSH user/key — it deploys to this same host's Docker).
*   The following environment variables must be set:
    *   `B2_BUCKET_NAME`
    *   `B2_APPLICATION_KEY_ID`
    *   `B2_APPLICATION_KEY`
    *   `GITEA_DB_PASSWORD`
    *   `DNSIMPLE_OAUTH_TOKEN`
    *   `CERTBOT_EMAIL`
    *   `GITEA_ADMIN_USERNAME`
    *   `GITEA_ADMIN_PASSWORD`
    *   `GITEA_ADMIN_EMAIL`
    *   `DISCORD_WEBHOOK`

**Manual Recovery Steps:**

1.  **Deploy the Base System:** First, run the `gitea-deploy.yml` playbook from your local machine.

    ```bash
    ansible-playbook -i /path/to/your/inventory playbooks/gitea-deploy.yml
    ```

2.  **Restore the Data:** Once the deployment is complete, run the `gitea-restore.yml` playbook.

    ```bash
    ansible-playbook -i /path/to/your/inventory playbooks/gitea-restore.yml
    ```