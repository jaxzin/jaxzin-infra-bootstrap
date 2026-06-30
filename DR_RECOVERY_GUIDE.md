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

`gitea-deploy.yml` is **two plays in one invocation**: Play 1 provisions the Gitea server on the NAS; **Play 2 deploys the Gitea Actions runner over SSH to `GITEA_RUNNER_HOST`** (via the `runner_host_seed` + `gitea_runner` roles — see `docs/runbooks/gitea-runner-host.md`). Running the bootstrap workflow therefore brings the runner online *as part of bootstrap* — there is **no separate "deploy the runner" step** and no Gitea-side trigger to fire.

> **Self-healing daemon restarts:** the Gitea stack now survives an out-of-band Container Manager / Docker daemon restart (e.g. a DSM auto-update) on its own — Play 1 enables Docker `live-restore` (so a daemon restart no longer stops containers) and deploys a reconcile watchdog (which revives any orphaned container, in dependency order, within minutes). This addresses the 2026-06-30 gitea-db orphan incident where a daemon restart left `gitea` crash-looping for ~3.5h. Full behavior, the backup maintenance-lock contract, the one-time `live-restore` enablement step, and the manual recovery one-liner: `docs/runbooks/gitea-stack-reconcile.md`.

### The manual seed

Disaster recovery has **one** irreducible, documented manual seed (a committed, version-controlled procedure — not improvisation): a self-hosted **GitHub Actions runner** on a dedicated tailnet-joined Linux host, acting as the bootstrap controller. The Gitea runner host (`GITEA_RUNNER_HOST`) is a separate machine — its Docker environment and deploy user are provisioned automatically by the `runner_host_seed` role when the bootstrap workflow runs.

> **PREREQ (easy to miss — no script enforces it):** the GitHub Actions runner (controller) must be a **dedicated tailnet-joined Linux box that is not the NAS**. It needs SSH access to `GITEA_RUNNER_HOST` and a working Docker install. Full detail: `docs/runbooks/gitea-runner-host.md`.

### Recovery Method 1: Automated GitHub Action (Recommended)

This is the primary and recommended method for disaster recovery. It uses GitHub Actions to ensure a repeatable and reliable execution.

**Prerequisites:**

*   The self-hosted GitHub Actions runner online on a dedicated tailnet-joined Linux host (the bootstrap controller — the single manual seed above). Play 2 deploys the Gitea runner **over SSH** to `GITEA_RUNNER_HOST`; the controller and the runner target are separate machines. Full contract: `docs/runbooks/gitea-runner-host.md`.

**Recovery Steps:**

1.  **Ensure the GitHub Runner is Available:** Make sure at least one self-hosted GitHub Actions runner is online and available on your local network.
2.  **Run the Bootstrap Workflow:** Manually trigger the `Bootstrap` workflow from the GitHub Actions tab. This runs `gitea-deploy.yml`: Play 1 provisions Gitea on the new NAS; **Play 2 brings the Gitea Actions runner online on its dedicated host** (it borrows the freshly-minted admin token from Play 1 to register itself). No further step is needed to get CI working.
3.  **Run the Restore Workflow:** Once the bootstrap is complete, manually trigger the `Restore Gitea Data` workflow. This requires a manual approval step before it runs the `gitea-restore.yml` playbook to populate the new instance with your backed-up data. The runner is already online from step 2, so restored repos' workflows can run immediately.

### Recovery Method 2: Manual Fallback

This method should only be used if GitHub Actions is unavailable or the automated workflow fails.

**Prerequisites:**

*   A new NAS host with Ansible and Docker installed.
*   A local checkout of this repository.
*   A valid Ansible inventory defining a `[nas]` group and a `[gitea_runner]` group, the latter as `<GITEA_RUNNER_HOST> ansible_user=<user> ansible_ssh_private_key_file=<key>` (SSH to the remote runner host). The `runner_host_seed` role will prepare the target if it has not been seeded yet. Full contract: `docs/runbooks/gitea-runner-host.md`.
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