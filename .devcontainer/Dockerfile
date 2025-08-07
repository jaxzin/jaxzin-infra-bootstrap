FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

# Install yq
ADD https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

# Install uv
RUN pip3 install --no-cache --break-system-packages uv