# Start from a replica of the Github runner image
FROM ghcr.io/catthehacker/ubuntu:act-24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies and a specific version of Ansible using pip
RUN apt-get update && \
    apt-get install -y python3 python3-pip sshpass git && \
    pip3 install --no-cache-dir --break-system-packages ansible==11.7.0 && \
    # Clean up the apt cache to reduce image size
    rm -rf /var/lib/apt/lists/*

# Set a working directory (optional, but good practice)
WORKDIR /work

