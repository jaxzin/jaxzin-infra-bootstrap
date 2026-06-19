#!/bin/bash
# =============================================================================
# Raspberry Pi OS first-boot provisioning for the Gitea Actions runner host.
# =============================================================================
# Bakes the bootstrap TRUST ANCHOR into the SD image so a freshly-flashed Pi is
# born CI-ready: the GitHub-side bootstrap (gitea-deploy.yml Play 2) can SSH in
# as the deploy account and `become` WITHOUT a separate seed run and WITHOUT an
# interactive sudo password. This is the IaC equivalent of
# playbooks/seed-runner-ssh.yml, moved to provisioning time (the SD flash) —
# the only out-of-band moment a hand-built Pi gets. See
# docs/runbooks/gitea-runner-host.md.
#
# HOW IT RUNS: Raspberry Pi OS runs this once at first boot when cmdline.txt
# carries the hook (the SAME mechanism Raspberry Pi Imager uses):
#   systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
# It executes as root, very early. It self-cleans (strips the hook from
# cmdline.txt + deletes itself) and the system reboots into normal operation.
#
# WHAT IT ESTABLISHES (idempotent — safe to re-run):
#   1. the `gitea-runner` deploy account (sudo group, key-only login)
#   2. that account's authorized_keys = the committed runner public key
#   3. passwordless sudo for it (/etc/sudoers.d/gitea-runner, visudo-validated)
#   4. SSH enabled
#
# DRIFT LOCK: the embedded RUNNER_PUBKEY MUST stay byte-identical to
# playbooks/files/gitea-runner.pub — tests/check_docker_tasks.py Check L fails
# the build if they diverge, so the baked anchor can't silently drift from the
# key CI actually authenticates with.
# =============================================================================

set -u
LOG=/var/log/gitea-runner-firstrun.log
exec >>"$LOG" 2>&1
echo "=== gitea-runner firstrun $(date -u) ==="

DEPLOY_USER="gitea-runner"
# Keep byte-identical to playbooks/files/gitea-runner.pub (locked by Check L).
RUNNER_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyJ5SnO2uP9OnSit49sBb2848Y1ZVczvQXvav8uRmse gitea-runner'

# 1. Deploy account. Created with no password, so it is KEY-ONLY: SSH public-key
#    auth still works (a locked password blocks interactive login, not key
#    login). Bookworm has no default `pi`, so this account must be created here.
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER" || true   # conventional; the drop-in below is what grants NOPASSWD

# 2. Authorized key = the committed runner public key.
HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$HOME_DIR/.ssh"
printf '%s\n' "$RUNNER_PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "$HOME_DIR/.ssh/authorized_keys"

# 3. Passwordless sudo. Write to a temp file, validate with `visudo -cf`, and
#    only then move it into place — a malformed drop-in can never land and lock
#    sudo out (same safety contract as seed-runner-ssh.yml). If validation
#    fails we skip it (recoverable via the seed) rather than risk the box.
SUDOERS_TMP="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$DEPLOY_USER" > "$SUDOERS_TMP"
if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/gitea-runner
  echo "installed /etc/sudoers.d/gitea-runner"
else
  echo "ERROR: sudoers validation failed — NOT installing (recover with seed-runner-ssh.yml)"
fi
rm -f "$SUDOERS_TMP"

# 4. RPi OS ships SSH disabled by default; enable it for next boot.
systemctl enable ssh >/dev/null 2>&1 || true

# 5. Self-clean: strip the first-boot hook from cmdline.txt and delete this
#    script so later boots are normal. Handle both Bookworm (/boot/firmware)
#    and older (/boot) boot-partition layouts.
for cmd in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$cmd" ] && sed -i 's| systemd\.run[^ ]*||g; s| systemd\.unit[^ ]*||g' "$cmd"
done
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh

echo "=== firstrun complete ==="
exit 0
