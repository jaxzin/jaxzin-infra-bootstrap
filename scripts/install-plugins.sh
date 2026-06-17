#!/bin/bash
set -uo pipefail

# === Install Claude Code plugins declared in .claude/settings.json ===
#
# Wired as a SessionStart hook so its output is visible in the session — unlike
# the cloud environment "Setup script", whose output you can't see. Reads
# `extraKnownMarketplaces` + `enabledPlugins` from .claude/settings.json and
# installs them via the `claude` CLI. Idempotent: safe to run every session.
#
# Intentionally verbose for debuggability. It never exits non-zero (a failing
# SessionStart hook shouldn't block the session) — it reports problems instead.
# Once it's working you can quiet it down.

log() { echo "[install-plugins] $*"; }

log "start: CLAUDE_CODE_REMOTE=${CLAUDE_CODE_REMOTE:-<unset>} user=$(id -un 2>/dev/null) pwd=$(pwd)"

# === Only run in cloud (Claude Code on the web) sessions ===
# Delete this guard to also run in local sessions.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  log "not a cloud session (CLAUDE_CODE_REMOTE != true) — skipping."
  exit 0
fi

# === Locate settings.json ===
SETTINGS="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
[[ -f "$SETTINGS" ]] || SETTINGS=".claude/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
  log "ERROR: no .claude/settings.json (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>}, cwd=$(pwd)) — nothing to do."
  exit 0
fi
log "using settings: $SETTINGS"

# === Required tools ===
for bin in claude jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "ERROR: required tool '$bin' not found on PATH."
    log "  PATH=$PATH"
    exit 0
  fi
done
log "claude: $(command -v claude) ($(claude --version 2>/dev/null | head -1))"

# === Register each declared marketplace ===
# github sources -> "owner/repo"; url/git -> URL; local -> path.
mapfile -t MARKETS < <(jq -r '
  (.extraKnownMarketplaces // {}) | to_entries[] | .value.source |
  if .source == "github" then .repo
  elif (.url  // empty) then .url
  elif (.path // empty) then .path
  else empty end
' "$SETTINGS")

for m in "${MARKETS[@]}"; do
  [[ -n "$m" ]] || continue
  log "marketplace add: $m"
  claude plugin marketplace add "$m" 2>&1 | sed 's/^/[install-plugins]   /'
  rc=${PIPESTATUS[0]}
  [[ $rc -eq 0 ]] && log "  marketplace add OK" || log "  marketplace add FAILED (exit $rc)"
done

# === Install each enabled plugin ("plugin@marketplace": true) ===
mapfile -t PLUGINS < <(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value==true) | .key' "$SETTINGS")

for p in "${PLUGINS[@]}"; do
  [[ -n "$p" ]] || continue
  log "install: $p"
  claude plugin install "$p" 2>&1 | sed 's/^/[install-plugins]   /'
  rc=${PIPESTATUS[0]}
  [[ $rc -eq 0 ]] && log "  install OK" || log "  install FAILED (exit $rc)"
done

log "done. currently installed:"
claude plugin list 2>&1 | sed 's/^/[install-plugins]   /' || true
exit 0
