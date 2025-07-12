# Start from a replica of the Github runner image
FROM ghcr.io/catthehacker/ubuntu:act-24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies, add the official Ansible PPA, and install Ansible
RUN apt-get update && \
    apt-get install -y python3 python3-pip sshpass git && \
    apt-get install -y wget gnupg software-properties-common && \
    wget -O- "https://keyserver.ubuntu.com/pks/lookup?fingerprint=on&op=get&search=0x6125E2A8C77F2818FB7BD15B93C4A3FD7BB9C367" | gpg --dearmour -o /usr/share/keyrings/ansible-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/ansible-archive-keyring.gpg] http://ppa.launchpad.net/ansible/ansible/ubuntu noble main" > /etc/apt/sources.list.d/ansible.list && \
    apt-get update && \
    apt-get install -y ansible && \
    # Clean up the apt cache to reduce image size
    rm -rf /var/lib/apt/lists/*

# Set a working directory (optional, but good practice)
WORKDIR /work

