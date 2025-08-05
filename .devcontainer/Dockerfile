FROM ghcr.io/mikefarah/yq AS yq-stage

#FROM mcr.microsoft.com/devcontainers/python:3.13-bullseye
#FROM mcr.microsoft.com/devcontainers/ansible:latest
FROM ubuntu:20.04

# Install yq from the yq-stage image
COPY --from=yq-stage /usr/bin/yq /usr/local/bin/yq

# Forcefully fix GPG key errors.
# 1. First 'update' ignores GPG errors to refresh package lists.
# 2. Reinstall the keyring package to get the new, valid keys.
# 3. Second 'update' runs securely, verifying with the new keys.
# 4. Unrelated, also installs 'uv' using pipx for the postCreateCommand of the devcontainer.
RUN apt-get -o Acquire::AllowInsecureRepositories=true update \
    && apt-get install -y --reinstall debian-archive-keyring \
    && apt-get update \
    && apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
    && pip3 install --no-cache --break-system-packages \
        uv \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache --break-system-packages \
            uv