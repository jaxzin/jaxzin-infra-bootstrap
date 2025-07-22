#!/bin/bash
set -euo pipefail

# === Config ===
read -p "Enter a name for this runner [runner1]: " RUNNER_NAME
RUNNER_NAME="${RUNNER_NAME:-runner1}"
read -p "Enter the repository URL [https://github.com/jaxzin/jaxzin-infra-bootstrap]: " REPO_URL
REPO_URL="${REPO_URL:-https://github.com/jaxzin/jaxzin-infra-bootstrap}"
INSTALL_DIR="/opt/github-runner/${RUNNER_NAME}"
read -p "Enter the runner version [2.326.0]: " RUNNER_VERSION
RUNNER_VERSION="${RUNNER_VERSION:-2.326.0}"
read -p "Enter the runner OS and architecture [linux-x64]: " RUNNER_OS_ARCH
RUNNER_OS_ARCH="${RUNNER_OS_ARCH:-linux-x64}"
RUNNER_ARCHIVE="actions-runner-${RUNNER_OS_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_DOWNLOAD="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"

echo "GitHub automatically adds 'self-hosted', OS, and architecture labels (e.g., 'linux', 'x64')."
read -p "Enter a comma-separated list of any additional custom labels (e.g. gpu,docker), or press Enter for none: " RUNNER_LABELS

# === Pre-checks ===
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "This script requires a runner registration token from GitHub."
  echo "Please generate a new one for this repository by visiting the following URL:"
  echo "$REPO_URL/settings/actions/runners/new"
  echo ""
  echo "After generating the token on that page, paste it here."
  read -sp "Please enter your GitHub registration token: " GITHUB_TOKEN
  echo
  if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "No token provided. Exiting." >&2
    exit 2
  fi
fi

# === Install ===
echo "This script will use sudo to install the runner and its dependencies."
echo "Creating install dir at $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Downloading runner v$RUNNER_VERSION..."
curl -fsSL -O "$RUNNER_DOWNLOAD"

echo "Extracting runner..."
tar xzf "$RUNNER_ARCHIVE"

echo "Configuring runner..."
./config.sh \
  --url "$REPO_URL" \
  --token "$GITHUB_TOKEN" \
  --name "$RUNNER_NAME" \
  ${RUNNER_LABELS:+--labels "$RUNNER_LABELS"} \
  --unattended

echo "Installing systemd service..."
sudo ./svc.sh install
sudo ./svc.sh start

echo "Runner installation complete. Use 'systemctl status actions.runner.*' to verify."