#!/usr/bin/env bash
#
# bootstrap-runner.sh — the ONE manual seed for the Gitea Actions runner host.
#
# Run this ONCE on the host (and again as the disaster-recovery step for
# that host). It is idempotent: re-running reconciles, it does not clobber.
# Everything after it is IaC — Play 2 of playbooks/gitea-deploy.yml deploys
# the runner container, and re-running the bootstrap workflow is the
# steady-state update path.
#
# TOPOLOGY THIS ASSUMES (documented contract — see
# docs/runbooks/gitea-runner-host.md):
#   * The self-hosted GitHub Actions runner (the bootstrap controller) and
#     the Gitea Actions runner run on the SAME machine. The deploy uses a
#     local connection from the CI job to that host's Docker — there is no
#     SSH / Tailscale SSH / key between them.
#   * That machine is NOT the Synology DSM/NAS. The NAS is Play 1's target
#     and is deliberately decoupled from the runner; running the runner on
#     the DSM reintroduces the whole NAS/dind problem class this removed.
#   * That machine is a tailnet node (kernel mode) so the runner CONTAINER
#     can reach Gitea over the tailnet and CI jobs can ssh tailnet hosts.
#     (Plain tailnet membership — NOT Tailscale SSH; nothing here uses it.)
#
# It stores NO secrets. If the host is not yet on the tailnet it runs an
# INTERACTIVE `tailscale up` (browser login, no --authkey, no --ssh); on a
# host already on the tailnet it does nothing to Tailscale.
#
# What it does (all idempotent):
#   1. Ensure Docker Engine is installed, enabled, running.
#   2. Ensure the deploy user exists and is in the `docker` group.
#   3. Ensure the host is on the tailnet (kernel mode, no Tailscale SSH).
#   4. Ensure the shared runner data dir exists (the CI job bind-mounts
#      this exact host path; the role writes the runner config/token here
#      and the host Docker daemon bind-mounts it into the runner
#      container, so the bytes must be coherent across both).
#
# Usage:
#   sudo ./bootstrap-runner.sh
#   sudo GITEA_RUNNER_DEPLOY_USER=ci ./bootstrap-runner.sh
#   sudo GITEA_RUNNER_DATA_PATH=/srv/gitea-runner ./bootstrap-runner.sh
#
set -euo pipefail

DEPLOY_USER="${GITEA_RUNNER_DEPLOY_USER:-gitea-runner}"
DATA_DIR="${GITEA_RUNNER_DATA_PATH:-/opt/gitea-runner}"

log()  { printf '\033[1;34m[bootstrap-runner]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap-runner] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap-runner] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use: sudo $0)"
command -v systemctl >/dev/null 2>&1 || die "this script expects a systemd host"

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  log "installing curl"
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq curl
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q curl
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q curl
  else die "no supported package manager (apt/dnf/yum) to install curl"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker present: $(docker --version)"
  else
    log "installing Docker Engine via get.docker.com"
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  log "docker service enabled and running"
}

ensure_deploy_user() {
  if id "$DEPLOY_USER" >/dev/null 2>&1; then
    log "deploy user '$DEPLOY_USER' exists"
  else
    log "creating deploy user '$DEPLOY_USER'"
    useradd --create-home --shell /bin/bash "$DEPLOY_USER"
  fi
  # Idempotent group add; `docker` group exists after ensure_docker.
  if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx docker; then
    log "'$DEPLOY_USER' already in docker group"
  else
    usermod -aG docker "$DEPLOY_USER"
    log "added '$DEPLOY_USER' to docker group"
  fi
}

ensure_tailnet() {
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale present: $(tailscale version | head -1)"
  else
    log "installing Tailscale via tailscale.com/install.sh"
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
  # NO Tailscale SSH and NO pref changes. The Ansible connection is local
  # (co-located), so Tailscale is only needed so the runner CONTAINER can
  # egress to the tailnet. `tailscale status` exits 0 when already up — in
  # that case touch nothing (don't reset prefs on a shared host). Only a
  # genuinely fresh host gets an interactive `tailscale up` (no --ssh).
  if tailscale status >/dev/null 2>&1; then
    log "host already on the tailnet — leaving Tailscale untouched"
  else
    log "host not on the tailnet yet — running interactive 'tailscale up'"
    log "authenticate in the browser when the login URL appears"
    tailscale up
  fi
}

ensure_data_dir() {
  if [ -d "$DATA_DIR" ]; then
    log "runner data dir '$DATA_DIR' exists"
  else
    log "creating runner data dir '$DATA_DIR'"
    mkdir -p "$DATA_DIR"
  fi
  # Owned by the deploy user; group-writable so the CI job (whatever uid
  # it runs as in-container) and the runner container can both use it.
  chown "$DEPLOY_USER:$DEPLOY_USER" "$DATA_DIR"
  chmod 0775 "$DATA_DIR"
}

print_summary() {
  echo
  log "=============================================================="
  log " Runner host bootstrap complete."
  log "   deploy user      : ${DEPLOY_USER}"
  log "   runner data dir  : ${DATA_DIR}"
  log
  log " No SSH key, no GITEA_RUNNER_SSH_KEY, no Tailscale SSH: the"
  log " bootstrap controller and the Gitea runner are the SAME host,"
  log " so Play 2 deploys over a LOCAL connection to this host's"
  log " Docker. Nothing else to set. Trigger the Bootstrap workflow"
  log " (from the branch/PR until merged) and Play 2 will create the"
  log " gitea-runner container here. See"
  log " docs/runbooks/gitea-runner-host.md."
  log "=============================================================="
}

main() {
  ensure_curl
  ensure_docker
  ensure_deploy_user
  ensure_tailnet
  ensure_data_dir
  print_summary
}

main "$@"
