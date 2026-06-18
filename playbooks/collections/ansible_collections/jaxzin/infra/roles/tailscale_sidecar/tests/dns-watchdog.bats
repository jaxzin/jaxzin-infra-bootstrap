#!/usr/bin/env bats
# Unit tests for ../files/dns-watchdog.sh — the tailscale_sidecar DNS
# healthcheck. Runs with stubbed `nslookup` and `tailscale` and a temp
# resolv.conf, so no Docker or tailnet is needed.
# Run: bats roles/tailscale_sidecar/tests/

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../files/dns-watchdog.sh"
    TMP="$(mktemp -d)"
    RESOLV="${TMP}/resolv.conf"
    STUBS="${TMP}/bin"
    TS_LOG="${TMP}/tailscale.log"
    MARKER="${TMP}/bounced"
    mkdir -p "$STUBS"

    # `tailscale` stub: logs its args; simulates that `--accept-dns=true`
    # re-applies DNS by creating MARKER (unless TS_STUB_NOFIX=1).
    cat > "${STUBS}/tailscale" <<'STUB'
#!/bin/sh
echo "$*" >> "$TS_LOG"
case "$*" in
  *"--accept-dns=true"*) [ "${TS_STUB_NOFIX:-0}" = "1" ] || : > "$MARKER" ;;
esac
exit 0
STUB

    # `nslookup` stub: succeeds iff NSLOOKUP_FORCE_OK=1 or MARKER exists
    # (i.e. a prior bounce repaired the forwarder).
    cat > "${STUBS}/nslookup" <<'STUB'
#!/bin/sh
{ [ "${NSLOOKUP_FORCE_OK:-0}" = "1" ] || [ -f "$MARKER" ]; } && exit 0
exit 1
STUB

    chmod +x "${STUBS}/tailscale" "${STUBS}/nslookup"

    export PATH="${STUBS}:${PATH}"
    export RESOLV_CONF="$RESOLV"
    export TS_LOG MARKER
    export TS_DNS_BOUNCE_SETTLE=0
    export TS_DNS_PROBE_NAME="probe.test"
    export TS_DNS_PROBE_RESOLVER="100.100.100.100"
}

teardown() {
    rm -rf "$TMP"
}

@test "heal: prepends 127.0.0.11 when missing" {
    printf 'nameserver 100.100.100.100\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=false   # skip probe; isolate the heal
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    head -n1 "$RESOLV" | grep -qx 'nameserver 127.0.0.11'
}

@test "heal: idempotent when 127.0.0.11 already present" {
    printf 'nameserver 127.0.0.11\nnameserver 100.100.100.100\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=false
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^nameserver 127.0.0.11$' "$RESOLV")" -eq 1 ]
}

@test "watchdog: upstream healthy -> no bounce, exit 0" {
    printf 'nameserver 127.0.0.11\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=true
    export NSLOOKUP_FORCE_OK=1
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$TS_LOG" ]   # tailscale never called
}

@test "watchdog: upstream broken then bounce repairs -> exit 0" {
    printf 'nameserver 127.0.0.11\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=true
    export NSLOOKUP_FORCE_OK=0   # only the bounce-created MARKER can fix it
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--accept-dns=false' "$TS_LOG"
    grep -q -- '--accept-dns=true' "$TS_LOG"
    echo "$output" | grep -q 'bouncing accept-dns'
}

@test "watchdog: upstream stays broken after bounce -> exit 1" {
    printf 'nameserver 127.0.0.11\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=true
    export NSLOOKUP_FORCE_OK=0
    export TS_STUB_NOFIX=1   # bounce does not repair
    run sh "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q -- '--accept-dns=false' "$TS_LOG"
    grep -q -- '--accept-dns=true' "$TS_LOG"
}

@test "accept_dns=false: heal only, probe skipped, exit 0" {
    printf 'nameserver 100.100.100.100\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=false
    export NSLOOKUP_FORCE_OK=0   # would fail, but probe must be skipped
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$TS_LOG" ]
    head -n1 "$RESOLV" | grep -qx 'nameserver 127.0.0.11'
}
