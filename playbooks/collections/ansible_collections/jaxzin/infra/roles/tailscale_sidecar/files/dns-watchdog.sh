#!/bin/sh
# dns-watchdog.sh — Docker healthcheck for the jaxzin.infra tailscale_sidecar.
#
# Fixes jaxzin.infra#7: in kernel-mode + shared-netns deployments, tailscaled
# can boot with an empty DefaultResolvers list, so MagicDNS (100.100.100.100)
# returns SERVFAIL for every query and all outbound DNS in the shared netns
# breaks. This script runs on the container's healthcheck interval and:
#
#   1. Downstream heal: keeps Docker's embedded resolver (127.0.0.11) at the
#      top of resolv.conf so containers sharing this netns can resolve Docker
#      service names. tailscaled (accept-dns=true) strips it on every restart.
#   2. Upstream watchdog: probes an external name against MagicDNS; if it
#      SERVFAILs (the empty-DefaultResolvers condition), it bounces accept-dns
#      false->true to force tailscaled to re-apply netmap DNS to its forwarder.
#      Verified non-disruptive — consumers stay up across the bounce.
#
# Exit 0 = healthy; exit 1 = upstream DNS still broken after a bounce attempt.
#
# Configuration (environment; the role injects these, defaults keep it runnable
# standalone and are what the bats tests drive):
#   RESOLV_CONF            resolv.conf path           (default /etc/resolv.conf)
#   TS_DNS_DOCKER_RESOLVER nameserver to keep on top  (default 127.0.0.11)
#   TS_DNS_ACCEPT_DNS      desired accept-dns value   (default true)
#   TS_DNS_PROBE_NAME      external name to resolve   (default one.one.one.one)
#   TS_DNS_PROBE_RESOLVER  resolver to query          (default 100.100.100.100)
#   TS_DNS_BOUNCE_SETTLE   seconds to wait mid-bounce (default 2)

set -u

RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
DOCKER_RESOLVER="${TS_DNS_DOCKER_RESOLVER:-127.0.0.11}"
ACCEPT_DNS="${TS_DNS_ACCEPT_DNS:-true}"
PROBE_NAME="${TS_DNS_PROBE_NAME:-one.one.one.one}"
PROBE_RESOLVER="${TS_DNS_PROBE_RESOLVER:-100.100.100.100}"
SETTLE="${TS_DNS_BOUNCE_SETTLE:-2}"

# 1. Downstream heal — ensure DOCKER_RESOLVER is the first nameserver line.
# Idempotent. Never `sed -i`: rename() returns EBUSY on the resolv.conf bind
# mount. Stage in a temp file, then overwrite in place with `>` (open+truncate).
heal_resolv_conf() {
    if grep -q "^nameserver ${DOCKER_RESOLVER}$" "$RESOLV_CONF"; then
        return 0
    fi
    _tmp="${TMPDIR:-/tmp}/dns-watchdog.resolv.$$"
    { printf 'nameserver %s\n' "$DOCKER_RESOLVER"; cat "$RESOLV_CONF"; } > "$_tmp" &&
        cat "$_tmp" > "$RESOLV_CONF"
    _rc=$?
    rm -f "$_tmp"
    [ "$_rc" -eq 0 ] && grep -q "^nameserver ${DOCKER_RESOLVER}$" "$RESOLV_CONF"
}

# 2. Upstream probe — can MagicDNS resolve an external name? busybox nslookup
# exits non-zero on SERVFAIL / empty answer. Bound it with `timeout` when
# available (busybox has it; some dev machines do not).
probe_upstream() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 2 nslookup "$PROBE_NAME" "$PROBE_RESOLVER" >/dev/null 2>&1
    else
        nslookup "$PROBE_NAME" "$PROBE_RESOLVER" >/dev/null 2>&1
    fi
}

# 3. Force tailscaled to re-apply netmap DNS to its forwarder.
bounce_accept_dns() {
    echo "dns-watchdog: upstream SERVFAIL detected; bouncing accept-dns to force re-apply" >&2
    tailscale set --accept-dns=false >/dev/null 2>&1
    sleep "$SETTLE"
    tailscale set --accept-dns="$ACCEPT_DNS" >/dev/null 2>&1
}

main() {
    heal_resolv_conf || exit 1

    # The upstream watchdog only applies when tailscaled manages DNS
    # (accept-dns=true). With accept-dns=false, external names are not expected
    # to resolve via MagicDNS, so probing/bouncing would be wrong.
    [ "$ACCEPT_DNS" = "true" ] || exit 0

    if probe_upstream; then
        exit 0
    fi

    bounce_accept_dns

    if probe_upstream; then
        exit 0
    fi
    exit 1
}

main
