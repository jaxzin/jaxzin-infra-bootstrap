#!/usr/bin/env bash
#
# bootstrap-runner.sh — the ONE manual seed for the Gitea Actions runner host.
#
# Run this ONCE on a fresh Linux host (and again as the disaster-recovery
# step for that host). It is idempotent: re-running reconciles, it does not
# clobber. It establishes the irreducible first trust — everything after it
# is IaC (Ansible Play 2 of playbooks/gitea-deploy.yml deploys the runner
# container over Tailscale SSH; re-running the bootstrap workflow is the
# steady-state update path).
#
# It deliberately stores NO secrets. Tailnet auth is the INTERACTIVE
# `tailscale up --ssh` browser-login flow — there is no pre-provisioned
# TS_AUTHKEY or SSH key to manage.
#
# What it does (all idempotent):
#   1. Ensure Docker Engine is installed, enabled, running.
#   2. Ensure the deploy user exists and is in the `docker` group
#      (so Ansible Play 2 runs become:false — no sudo on this host).
#   3. Ensure Tailscale is installed and run `tailscale up --ssh`
#      INTERACTIVELY (operator authenticates in a browser). This puts the
#      host on the tailnet and exposes Tailscale SSH as the Ansible
#      connection channel — no SSH key to generate, store, or paste.
#   4. Print the host's MagicDNS name + deploy user for the CI config.
#
# PREREQUISITES (see docs/runbooks/gitea-runner-host.md — these are NOT
# checked here because they live outside this host):
#   * The environment that runs the bootstrap workflow (the self-hosted
#     GitHub Actions runner) MUST itself be on the tailnet and able to
#     reach this host over Tailscale SSH.
#   * The tailnet ACL policy MUST permit that CI identity to Tailscale-SSH
#     into this host as the deploy user.
#
# Before enabling Tailscale SSH (the one step that can drop your current
# session if you're connected over Tailscale) the script PROMPTS for
# confirmation — default No, so you can nope out and re-run later. For an
# unattended run, set BOOTSTRAP_RUNNER_ASSUME_YES=1 to skip that prompt.
#
# Usage:
#   sudo ./bootstrap-runner.sh
#   sudo GITEA_RUNNER_DEPLOY_USER=ci ./bootstrap-runner.sh
#   sudo BOOTSTRAP_RUNNER_ASSUME_YES=1 ./bootstrap-runner.sh   # unattended
#
set -euo pipefail

DEPLOY_USER="${GITEA_RUNNER_DEPLOY_USER:-gitea-runner}"

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

# Escape hatch before the one step that can sever the operator's own
# session. stdin is often the `curl | sudo bash` pipe, so prompt/read on
# /dev/tty (NOT stdin) or it would consume script bytes / get EOF.
confirm_ssh_enable() {
  if [ "${BOOTSTRAP_RUNNER_ASSUME_YES:-}" = "1" ]; then
    warn "BOOTSTRAP_RUNNER_ASSUME_YES=1 set — skipping the disconnect confirmation"
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    die "the next step enables Tailscale SSH and may drop this session, but there is no terminal to confirm on. Re-run from a terminal, or set BOOTSTRAP_RUNNER_ASSUME_YES=1 for an unattended run."
  fi
  {
    printf '\n'
    printf '\033[1;33m[bootstrap-runner] ⚠  NEXT STEP ENABLES TAILSCALE SSH.\033[0m\n'
    printf '   If you are connected to this host over Tailscale, THIS SSH\n'
    printf '   SESSION MAY DISCONNECT.\n'
    printf '   It is safe: this script is idempotent. Reconnect (via\n'
    printf '   Tailscale SSH) and re-run — it skips everything already done.\n'
    printf '   To avoid the disconnect entirely, run this from the host'\''s\n'
    printf '   local console instead.\n'
    printf '[bootstrap-runner] Proceed and enable Tailscale SSH now? [y/N] '
  } > /dev/tty
  local reply=""
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    [yY] | [yY][eE][sS]) log "operator confirmed — enabling Tailscale SSH" ;;
    *)
      warn "Aborted by operator before the Tailscale SSH change."
      warn "INCOMPLETE: Tailscale SSH is NOT enabled yet (Docker + deploy"
      warn "user + group WERE set up). Re-run this script when ready —"
      warn "it is idempotent and will resume at this step."
      exit 0
      ;;
  esac
}

# True when Tailscale SSH is ALREADY on (RunSSH pref). Lets a re-run
# short-circuit: no scary disconnect prompt, no no-op `set`, just the
# summary. Best-effort: if it can't tell, returns false and we fall
# through to the (harmless) confirm+set path.
tailscale_ssh_already_enabled() {
  command -v python3 >/dev/null 2>&1 || return 1
  tailscale debug prefs 2>/dev/null | python3 -c \
    'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get("RunSSH") else 1)' 2>/dev/null
}

ensure_tailscale_ssh() {
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale present: $(tailscale version | head -1)"
  else
    log "installing Tailscale via tailscale.com/install.sh"
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled

  if tailscale_ssh_already_enabled; then
    log "Tailscale SSH already enabled — nothing to change (idempotent re-run)"
    return 0
  fi

  confirm_ssh_enable

  # `--accept-risk=lose-ssh`: enabling Tailscale SSH reroutes SSH and can
  # drop the in-flight session; Tailscale aborts without this. The
  # operator just acknowledged it via confirm_ssh_enable above.
  #
  # Idempotent + SAFE on an already-configured tailnet node:
  #   * Already logged in  -> `tailscale set --ssh` flips ONLY the SSH
  #     preference and leaves every other pref (tags, routes, exit-node,
  #     accept-dns, ...) untouched. A bare `tailscale up --ssh` would
  #     instead reset unspecified prefs to defaults (or error), which
  #     would clobber an existing node like a shared homelab host.
  #   * Not logged in yet  -> interactive `tailscale up --ssh` (no
  #     --authkey): prints a browser login URL for the operator. This
  #     only happens on a genuinely fresh host.
  # `tailscale status` exits 0 only when the node is up/logged in.
  if tailscale status >/dev/null 2>&1; then
    log "host already on the tailnet — enabling Tailscale SSH only (other prefs untouched)"
    tailscale set --ssh --accept-risk=lose-ssh
  else
    log "host not on the tailnet yet — running interactive 'tailscale up --ssh'"
    log "authenticate in the browser when the login URL appears"
    tailscale up --ssh --accept-risk=lose-ssh
  fi
}

print_summary() {
  local dnsname=""
  if command -v python3 >/dev/null 2>&1; then
    dnsname="$(tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
  fi
  echo
  log "=============================================================="
  log " Runner host bootstrap complete."
  log "   deploy user           : ${DEPLOY_USER}"
  if [ -n "$dnsname" ]; then
    log "   tailnet MagicDNS name : ${dnsname}"
  else
    log "   tailnet MagicDNS name : run 'tailscale status' and read this"
    log "                           host's name (the Self/first entry)"
  fi
  log
  log " Set these in the jaxzin-infra-bootstrap GitHub repo:"
  log "   Secret   GITEA_RUNNER_HOST      = <the MagicDNS name above>"
  log "   Variable GITEA_RUNNER_SSH_USER  = ${DEPLOY_USER}"
  log
  log " No SSH key and no GITEA_RUNNER_SSH_KEY are needed: the Ansible"
  log " connection is Tailscale SSH. Ensure the GitHub self-hosted"
  log " runner is on the tailnet and the tailnet ACL permits it to SSH"
  log " here as '${DEPLOY_USER}' (see docs/runbooks/gitea-runner-host.md)."
  log "=============================================================="
}

main() {
  ensure_curl
  ensure_docker
  ensure_deploy_user
  ensure_tailscale_ssh
  print_summary
}

main "$@"
