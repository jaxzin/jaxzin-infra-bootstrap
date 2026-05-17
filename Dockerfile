# Start from a replica of the Github runner image
FROM ghcr.io/catthehacker/ubuntu:act-24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies and a specific version of Ansible using pip
# Add iptables support for Docker-in-Docker
# `docker` is the Docker SDK for Python. community.docker.docker_container
# imports it (and its `requests` dep). It is REQUIRED here because the
# gitea_runner deploy (gitea-deploy.yml Play 2) runs locally in THIS image
# (connection: local, co-located with the Gitea runner) and manages the
# host Docker daemon — there is no remote host whose Python provides it.
# See docs/runbooks/gitea-runner-host.md; locked in by
# tests/check_docker_tasks.py Check J.
RUN apt-get update && \
    apt-get install -y python3 python3-pip sshpass git iptables dnsutils && \
    pip3 install --no-cache-dir --break-system-packages ansible==11.7.0 docker==7.1.0 && \
    # Clean up the apt cache to reduce image size
    rm -rf /var/lib/apt/lists/*

# Set a working directory (optional, but good practice)
WORKDIR /work

