# Start from a replica of the Github runner image
FROM ghcr.io/catthehacker/ubuntu:act-24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies and a specific version of Ansible using pip
# Add iptables support for Docker-in-Docker
# `docker` is the Docker SDK for Python. community.docker.docker_container
# imports it (and its `requests` dep). The real consumer moved off this
# image: gitea_runner (gitea-deploy.yml Play 2) now runs community.docker
# OVER SSH on GITEA_RUNNER_HOST (under become), where the runner_host_seed
# role installs the SDK on the target — so this copy is no longer required
# by the deploy. It is kept as cheap-insurance for any community.docker
# step that runs connection: local in this image. See
# docs/runbooks/gitea-runner-host.md; locked in by
# tests/check_docker_tasks.py Check J.
RUN apt-get update && \
    apt-get install -y python3 python3-pip sshpass git iptables dnsutils && \
    pip3 install --no-cache-dir --break-system-packages ansible==11.7.0 docker==7.1.0 && \
    # Clean up the apt cache to reduce image size
    rm -rf /var/lib/apt/lists/*

# Set a working directory (optional, but good practice)
WORKDIR /work

