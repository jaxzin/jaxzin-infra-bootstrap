#!/bin/bash
set -e

# Setup uv with all the Ansible Molecule dependencies
# Keep the uv virtual environment in the container, rather than the workspace which might be shared with the host
#  and likely won't have the Python interpreter installed in the same location to symlink to.

# Create a virtual environment for uv and install the project dependencies
uv sync

# Install the development collection so that Molecule can reference it
uv run ansible-galaxy collection install jaxzin.infra -p ./collections

# Add molecule autocomplete to the devcontainer shell
echo 'eval "$(_MOLECULE_COMPLETE=SHELL_source uv run molecule)"' >> ~/.bashrc

# Drop into the virtual environment
echo 'source /home/vscode/.venv/bin/activate' >> ~/.bashrc

echo "Devcontainer setup complete. Molecule and other tools are installed."