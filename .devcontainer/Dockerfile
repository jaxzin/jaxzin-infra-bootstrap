#FROM mcr.microsoft.com/devcontainers/python:3.13
#FROM mcr.microsoft.com/devcontainers/ansible:latest
FROM ubuntu:24.04

# Forcefully fix GPG key errors.
# 1. First 'update' ignores GPG errors to refresh package lists.
# 2. Reinstall the keyring package to get the new, valid keys.
# 3. Second 'update' runs securely, verifying with the new keys.
# 4. Unrelated, also installs 'uv' using pipx for the postCreateCommand of the devcontainer.
RUN apt-get -o Acquire::AllowInsecureRepositories=true update \
    && apt-get install -y --reinstall debian-archive-keyring \
    && apt-get update \
    && pipx install \
        uv \
    && rm -rf /var/lib/apt/lists/*