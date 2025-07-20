# Disaster Recovery Guide

This guide provides instructions for setting up and recovering from each of the three disaster recovery tiers.

## Tier 1: Btrfs Snapshots (Local Fast Recovery)

(Content unchanged)

## Tier 2: Hyper Backup (Remote/Offsite Protection)

(Content unchanged)

## Tier 3: Gitea Archive (Portable Disaster Recovery)

This tier uses the application-native backup and restore functionality of Gitea, creating a portable archive that can be restored to any new host.

### Automated Backup Setup

The `gitea-deploy.yml` playbook automatically **configures and enables** a daily, automated backup. It deploys a script to the NAS and schedules it to run daily via a cron job. This script stops Gitea, creates a full dump, uploads it to Backblaze B2, and restarts Gitea. The playbook also deploys Certbot for SSL certificate management and a Gitea runner for CI/CD.

### Recovery Method 1: Automated GitHub Action (Recommended)

This is the primary and recommended method for disaster recovery. It uses GitHub Actions to ensure a repeatable and reliable execution.

**Recovery Steps:**

1.  **Ensure a Runner is Available:** Make sure at least one self-hosted GitHub Actions runner is online and available on your local network.
2.  **Run the Bootstrap Workflow:** Manually trigger the `Bootstrap` workflow from the GitHub Actions tab. This will run the `gitea-deploy.yml` playbook to provision the base system on the new host.
3.  **Run the Restore Workflow:** Once the bootstrap is complete, manually trigger the `Restore Gitea Data` workflow. This requires a manual approval step before it runs the `gitea-restore.yml` playbook to populate the new instance with your backed-up data.

### Recovery Method 2: Manual Fallback

This method should only be used if GitHub Actions is unavailable or the automated workflow fails.

**Prerequisites:**

*   A new host with Ansible and Docker installed.
*   A local checkout of this repository.
*   A valid Ansible inventory file for the new host.
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