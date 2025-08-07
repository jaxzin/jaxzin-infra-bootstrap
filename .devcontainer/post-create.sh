#!/bin/bash
set -e

# Read the first argument as the container workspace directory
WORKSPACE_DIR="$1"
if [ -z "$WORKSPACE_DIR" ]; then
    echo "Error: No workspace directory provided."
    exit 1
fi

echo "PATH=$PATH"
echo "which python3: $(which python3 || echo 'not found')"
echo "python3 version: $(python3 --version || echo 'not found')"
echo "uv version: $(uv --version || echo 'uv not found')"

# Setup uv with all the Ansible Molecule dependencies

# If a project-local .venv exists (e.g. synced from host), remove it
if [ -L .venv ] || [ -d .venv ]; then
    echo "⚠️  Removing existing project .venv to avoid uv resolution conflicts"
    rm -rf .venv
fi

# Determine the UV_LINK_MODE based on whether the workspace is bind-mounted or not
if grep -F " ${WORKSPACE_DIR} " /proc/self/mountinfo | grep -q "bind"; then
  echo "📦 Detected bind-mounted workspace at $WORKSPACE_DIR — using UV_LINK_MODE=copy"
  export UV_LINK_MODE=copy
else
  echo "📁 Detected internal (non-bind) workspace — using default UV link mode behavior."
fi


# Create a virtual environment for uv and install the project dependencies
uv sync

# Install the development collection so that Molecule can reference it
uv run ansible-galaxy collection install jaxzin.infra -p ./collections
uv run make deps

# Add molecule autocomplete to the devcontainer shell
echo 'eval "$(_MOLECULE_COMPLETE=SHELL_source uv run molecule)"' >> /home/vscode/.bashrc

# Drop into the virtual environment
echo source "${WORKSPACE_DIR}/.venv/bin/activate" >> /home/vscode/.bashrc

# Ensure the collections path is set correctly for Ansible development
echo "export ANSIBLE_COLLECTIONS_PATH=\"\$(pwd)/collections:\$(uv run ansible-config dump --format json | jq -r '.[] | select(.name == \"COLLECTIONS_PATHS\") | .value[]' | grep -vxF \$(pwd)/collections | paste -sd: -)\"" >> /home/vscode/.bashrc

echo "Devcontainer setup complete. Molecule and other tools are installed."