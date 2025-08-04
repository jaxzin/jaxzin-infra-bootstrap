#!/bin/bash
set -e

echo "PATH=$PATH"
echo "which python3: $(which python3 || echo 'not found')"
echo "python3 version: $(python3 --version || echo 'not found')"
echo "uv version: $(uv --version || echo 'uv not found')"

# Setup uv with all the Ansible Molecule dependencies
# Keep the uv virtual environment in the container, rather than the workspace which might be shared with the host
#  and likely won't have the Python interpreter installed in the same location to symlink to.
uv venv /home/vscode/.venv
export UV_VENV_PATH=/home/vscode/.venv

# Create a virtual environment for uv and install the project dependencies
uv sync

# Install the development collection so that Molecule can reference it
uv run ansible-galaxy collection install jaxzin.infra -p ./collections
uv run make deps

# Add molecule autocomplete to the devcontainer shell
echo 'eval "$(_MOLECULE_COMPLETE=SHELL_source uv run molecule)"' >> /home/vscode/.bashrc

# Drop into the virtual environment
echo 'source /home/vscode/.venv/bin/activate' >> /home/vscode/.bashrc

# Ensure the collections path is set correctly for Ansible development
echo "export ANSIBLE_COLLECTIONS_PATH=\"\$(pwd)/collections:\$(uv run ansible-config dump --format json | jq -r '.[] | select(.name == \"COLLECTIONS_PATHS\") | .value[]' | grep -vxF \$(pwd)/collections | paste -sd: -)\"" >> /home/vscode/.bashrc

echo "Devcontainer setup complete. Molecule and other tools are installed."