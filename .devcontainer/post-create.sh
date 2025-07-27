#!/bin/bash
set -e

# Setup uv with all the Ansible Molecule dependencies
# Keep the uv virtual environment in the container, rather than the workspace which might be shared with the host
#  and likely won't have the Python interpreter installed in the same location to symlink to.

uv venv /home/vscode/.venv && \
  . /home/vscode/.venv/bin/activate && \
  uv sync --extra dev --active

# Add molecule autocomplete to the devcontainer shell
source /home/vscode/.venv/bin/activate
echo 'eval "$(_MOLECULE_COMPLETE=SHELL_source molecule)"' >> ~/.bashrc

echo "Devcontainer setup complete. Molecule and other tools are installed."