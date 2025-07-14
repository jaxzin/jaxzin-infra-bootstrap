# Contributing to the Project

Thank you for your interest in contributing! This document provides guidance for setting up your local development environment and running tests.

## Local Development with `act`

To test the Ansible playbooks and GitHub Actions workflows locally before committing, you can use `act`. This tool allows you to run the workflows in a Docker container that closely mimics the GitHub Actions runners.

### Prerequisites

Before you can use `act`, you need to create two files in the root of the project to provide the necessary secrets and variables.

**`.secrets`** (for sensitive values):
```
NAS_SSH_PASSWORD=<your_ssh_password>
SSH_KEY=<your_private_ssh_key>
B2_ACCESS_KEY=<your_b2_access_key>
B2_SECRET_KEY=<your_b2_secret_key>
DISCORD_WEBHOOK_URL=<your_discord_webhook>
GITEA_DB_PASSWORD=<your_gitea_db_password>
DNSIMPLE_OAUTH_TOKEN=<your_dnsimple_oauth_token>
```

**`.vars`** (for non-secret configuration):
```
NAS_HOST=<your_nas_host>
NAS_SSH_USER=<your_ssh_user>
CERTBOT_EMAIL=<your_certbot_email>
```

**Important:** These files should not be committed to the repository. The `.gitignore` file is already configured to ignore them.

### Running the Tests

Once you've created these files, you can run the `bootstrap.yml` workflow locally using the `Makefile`:

```bash
make act-test
```

This command will execute the workflow in a Docker container that mirrors the `ubuntu-latest` environment used by GitHub Actions.
