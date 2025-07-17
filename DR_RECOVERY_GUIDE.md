# Disaster Recovery Guide

This guide provides instructions for setting up and recovering from each of the three disaster recovery tiers.

## Tier 1: Btrfs Snapshots (Local Fast Recovery)

### Setup

1.  **Run the Ansible Playbook:** Execute the `gitea-backup.yml` playbook. This will ensure the Synology "Snapshot Replication" package is installed.
2.  **Configure Snapshot Schedule (One-Time Manual Step):**
    *   Log in to your Synology DSM.
    *   Open the **Snapshot Replication** package.
    *   Navigate to **Snapshots** > **Shared Folder**.
    *   Select the `docker` shared folder.
    *   Click **Settings** > **Schedule**.
    *   Enable the schedule and configure your desired snapshot frequency (e.g., daily).
    *   Go to the **Retention** tab and configure a retention policy (e.g., keep 7 daily snapshots).

### Recovery

1.  **Stop Gitea:** `docker stop gitea`
2.  **Restore from Snapshot:**
    *   Open Snapshot Replication in DSM.
    *   Go to the **Recovery** tab.
    *   Select the "docker" shared folder.
    *   Choose the desired snapshot and click "Recover".
3.  **Start Gitea:** `docker start gitea`

## Tier 2: Hyper Backup (Remote/Offsite Protection)

### Setup

1.  **Install Hyper Backup:** Install the "Hyper Backup" package from the Package Center.
2.  **Create Backup Task:**
    *   Open Hyper Backup and click the "+" to create a new "Data backup task".
    *   Select your backup destination (e.g., Backblaze B2).
    *   For the source, select the `/volume1/docker/gitea/backups` directory.
    *   Configure your backup schedule, retention policy, and encryption.
3.  **Run the Ansible Playbook:** The playbook ensures the source directory exists.

### Recovery

1.  **Install Hyper Backup:** On a new Synology NAS, install Hyper Backup.
2.  **Restore from Backup:**
    *   Open Hyper Backup and click "Restore" > "Data".
    *   Select your backup task and follow the wizard to restore the `backups` directory.
3.  **Follow Tier 3 Recovery:** Once the dump files are restored, follow the Tier 3 recovery instructions.

## Tier 3: Gitea Archive (Portable Disaster Recovery)

### Setup

1.  **Run the Ansible Playbook:** The `gitea-backup.yml` playbook will deploy the dump script and schedule it.

### Recovery

1.  **Retrieve Dump File:** Download the desired `gitea-dump-YYYY-MM-DD.tar.gz` file from your Hyper Backup destination (e.g., Backblaze B2).
2.  **Set up New Host:**
    *   Install Docker and Docker Compose.
    *   Create a `docker-compose.yml` for Gitea and MySQL.
    *   Create the necessary directory structure: `/volume1/docker/gitea`.
3.  **Restore Gitea:**
    *   Start the MySQL container.
    *   Copy the dump file to the new host.
    *   Run the following command to restore the dump:
        ```bash
        docker run --rm -v /volume1/docker/gitea:/data -v $(pwd)/gitea-dump.tar.gz:/tmp/gitea-dump.tar.gz gitea/gitea:latest gitea restore --from /tmp/gitea-dump.tar.gz
        ```
4.  **Start Gitea:** `docker-compose up -d gitea`