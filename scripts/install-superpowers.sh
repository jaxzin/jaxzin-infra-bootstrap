#!/bin/bash
set -euo pipefail

# === Install the Superpowers plugin for Claude Code on the web ===
#
# The marketplace and plugin are declared in .claude/settings.json
# (extraKnownMarketplaces + enabledPlugins), which Claude Code on the web
# auto-installs at session start. This script is the explicit, forced
# installer that guarantees the plugin is present even if that auto-install
# is skipped. It is wired in as a SessionStart hook.
#
# Idempotent: safe to run on every session start.

MARKETPLACE_REPO="obra/superpowers-marketplace"
MARKETPLACE_NAME="superpowers-marketplace"
PLUGIN="superpowers@${MARKETPLACE_NAME}"

# === Only force-install in cloud (Claude Code on the web) sessions ===
# Local sessions pick up Superpowers through the normal enabledPlugins prompt.
# Delete this guard if you want the install to run in local sessions too.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

# === Need the Claude Code CLI on PATH to manage plugins ===
if ! command -v claude >/dev/null 2>&1; then
  echo "[install-superpowers] 'claude' CLI not found on PATH; skipping." >&2
  exit 0
fi

# === Register the marketplace and install the plugin (no-ops if already present) ===
echo "[install-superpowers] Registering marketplace ${MARKETPLACE_REPO}..." >&2
claude plugin marketplace add "${MARKETPLACE_REPO}" >&2 || true

echo "[install-superpowers] Installing ${PLUGIN}..." >&2
claude plugin install "${PLUGIN}" >&2 || true

echo "[install-superpowers] Done." >&2
exit 0
