# tailscale_sidecar DNS Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the `tailscale_sidecar` from silently breaking all outbound DNS in its shared network namespace when `tailscaled` boots with an empty `DefaultResolvers` list (jaxzin.infra#7), by adding a self-healing DNS Docker healthcheck that repairs both halves of the resolver chain.

**Architecture:** A single static POSIX shell script (`dns-watchdog.sh`) runs as the sidecar's Docker healthcheck on a fixed interval. Each run (1) re-prepends Docker's embedded resolver `127.0.0.11` to `/etc/resolv.conf` (downstream half), and (2) when `accept_dns` is on, probes an external name against MagicDNS and — if it SERVFAILs — bounces `accept-dns` false→true to force `tailscaled` to re-apply its netmap DNS to the forwarder (upstream half). The script is config-driven by environment variables injected by the role, which makes its logic unit-testable with `bats` + command stubs (no Docker or tailnet required). The role installs the script on the host and bind-mounts it into the container.

**Tech Stack:** Ansible role (`community.docker`), POSIX `sh` (runs inside the Alpine/busybox `ghcr.io/tailscale/tailscale` image), `bats-core` + `shellcheck` for tests, GitHub Actions (`ansible-lint` already; add `shellcheck` + `bats` jobs).

---

## Background (read before starting)

The bug, root cause, recovery, and the durable-fix decision are documented in [GitHub issue #7](https://github.com/jaxzin/ansible-collection-infra/issues/7). One-paragraph summary:

In kernel-mode + shared-netns deployments, `tailscaled` (running `directManager`, `dns=true`) can finish startup **without** applying the tailnet DNS config to its forwarder — `DefaultResolvers` ends up empty, so MagicDNS (`100.100.100.100`) returns **SERVFAIL for every query**. Every container sharing the sidecar's netns (e.g. Gitea via `network_mode: container:<sidecar>`) then has broken outbound DNS — but the funnel/serve path keeps working, so the sidecar *looks* healthy. The verified non-disruptive recovery is `tailscale set --accept-dns=false ; sleep 2 ; tailscale set --accept-dns=true`, which forces `tailscaled` to re-apply the netmap DNS config.

This collection's `tailscale_sidecar` role currently has **neither** the downstream resolv.conf self-heal (which already exists in the consuming bootstrap repo) **nor** the upstream watchdog. This plan adds both, plus the `dns_servers` wiring that makes the chain work, in one canonical place.

**Design decisions already approved (do not re-litigate):**
1. **Mechanism:** one Docker healthcheck that folds both halves into `dns-watchdog.sh`. (Docker allows only one healthcheck per container, so a second "dedicated" healthcheck is not an option.)
2. **Health semantics:** after attempting the bounce, re-probe; report `unhealthy` **only if** external DNS still fails. Informational only — under `restart_policy: always`, Docker does not restart unhealthy containers, so it never disrupts consumers.
3. **Variable naming:** `tailscale_dns_watchdog_*` / `tailscale_dns_probe_*` / `tailscale_dns_servers` (the `tailscale_` prefix is the role's stable public API; see `.ansible-lint`).
4. **Scope:** DNS fix only. The bootstrap copy's auth-key expiry assertions and userspace-networking mode are orthogonal and become a separate follow-up issue — **do not** add them here.

---

## File Structure

| File | New/Modified | Responsibility |
| --- | --- | --- |
| `roles/tailscale_sidecar/files/dns-watchdog.sh` | **Create** | The healthcheck logic: resolv.conf heal + upstream probe + accept-dns bounce. Static, env-driven, POSIX `sh`. Ships in the published collection. |
| `roles/tailscale_sidecar/tests/dns-watchdog.bats` | **Create** | `bats` unit tests for the script using stubbed `nslookup`/`tailscale` and a temp resolv.conf. Excluded from the published tarball. |
| `roles/tailscale_sidecar/defaults/main.yml` | Modify | Add the `tailscale_dns_*` defaults. |
| `roles/tailscale_sidecar/meta/main.yml` | Modify | Add `argument_specs` entries for the new variables. |
| `roles/tailscale_sidecar/tasks/main.yml` | Modify | Install the script on the host; add `dns_servers`, `healthcheck`, watchdog env vars, and the script bind-mount to the container; add a post-deploy reconcile task. |
| `roles/tailscale_sidecar/README.md` | Modify | Document the watchdog behavior and the new variables. |
| `.github/workflows/lint.yml` | Modify | Add `shellcheck` and `bats` CI jobs. |
| `galaxy.yml` | Modify | Add `roles/tailscale_sidecar/tests` to `build_ignore`. |

---

## Task 1: DNS watchdog script + bats tests (TDD core)

This is the heart of the change — the only place real logic lives — so it is built test-first.

**Files:**
- Create: `roles/tailscale_sidecar/files/dns-watchdog.sh`
- Test: `roles/tailscale_sidecar/tests/dns-watchdog.bats`

- [ ] **Step 1: Pre-flight — confirm the runtime tools exist in the image**

Run (requires Docker locally; if Docker is unavailable, skip — busybox always provides `nslookup` and `timeout`, and `tailscale` is the image's primary binary):

```bash
docker run --rm --entrypoint sh ghcr.io/tailscale/tailscale:latest \
  -c 'command -v nslookup tailscale timeout && echo OK'
```

Expected: three paths printed followed by `OK`. If `nslookup` is missing, stop and revisit the probe tool choice before continuing (do not silently swap tools — that is a design change).

- [ ] **Step 2: Install bats + shellcheck locally**

Run:

```bash
brew install bats-core shellcheck   # macOS dev machine
bats --version && shellcheck --version
```

Expected: both report a version. (CI installs these in Task 2.)

- [ ] **Step 3: Write the failing bats tests**

Create `roles/tailscale_sidecar/tests/dns-watchdog.bats`:

```bash
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
}

@test "watchdog: upstream stays broken after bounce -> exit 1" {
    printf 'nameserver 127.0.0.11\n' > "$RESOLV"
    export TS_DNS_ACCEPT_DNS=true
    export NSLOOKUP_FORCE_OK=0
    export TS_STUB_NOFIX=1   # bounce does not repair
    run sh "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q -- '--accept-dns=false' "$TS_LOG"
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
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bats roles/tailscale_sidecar/tests/dns-watchdog.bats`
Expected: FAIL — every test errors because `roles/tailscale_sidecar/files/dns-watchdog.sh` does not exist yet (`sh: ...: No such file or directory`).

- [ ] **Step 5: Write the script to make the tests pass**

Create `roles/tailscale_sidecar/files/dns-watchdog.sh`:

```sh
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
        timeout 3 nslookup "$PROBE_NAME" "$PROBE_RESOLVER" >/dev/null 2>&1
    else
        nslookup "$PROBE_NAME" "$PROBE_RESOLVER" >/dev/null 2>&1
    fi
}

# 3. Force tailscaled to re-apply netmap DNS to its forwarder.
bounce_accept_dns() {
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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats roles/tailscale_sidecar/tests/dns-watchdog.bats`
Expected: PASS — `6 tests, 0 failures`.

- [ ] **Step 7: Lint the script with shellcheck**

Run: `shellcheck roles/tailscale_sidecar/files/dns-watchdog.sh`
Expected: no output, exit 0. (If shellcheck flags anything, fix it and re-run Steps 6–7.)

- [ ] **Step 8: Commit**

```bash
git add roles/tailscale_sidecar/files/dns-watchdog.sh \
        roles/tailscale_sidecar/tests/dns-watchdog.bats
git commit -m "feat(tailscale_sidecar): add DNS self-heal + upstream watchdog script

Healthcheck script that keeps Docker's embedded resolver (127.0.0.11) at
the top of resolv.conf and, when accept-dns is on, detects the empty
DefaultResolvers SERVFAIL condition and bounces accept-dns to force
tailscaled to re-apply netmap DNS. Unit-tested with bats + stubs.

Refs #7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: CI — shellcheck + bats jobs

Wire the new tests into CI so the script logic is verified on every push/PR, matching the existing pinned-tooling philosophy in `lint.yml`.

**Files:**
- Modify: `.github/workflows/lint.yml`

- [ ] **Step 1: Add the two jobs to the workflow**

In `.github/workflows/lint.yml`, the existing `jobs:` map contains a single `ansible-lint` job. Add these two sibling jobs at the same indentation level (after the `ansible-lint` job's last step):

```yaml
  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - name: Check out the collection
        uses: actions/checkout@v6.0.3

      - name: Run shellcheck on the DNS watchdog script
        run: shellcheck roles/tailscale_sidecar/files/dns-watchdog.sh

  bats:
    name: bats
    runs-on: ubuntu-latest
    steps:
      - name: Check out the collection
        uses: actions/checkout@v6.0.3

      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats

      - name: Run the DNS watchdog unit tests
        run: bats roles/tailscale_sidecar/tests/
```

> Note: `shellcheck` is preinstalled on GitHub-hosted `ubuntu-latest` runners, so that job needs no install step. `bats` is not, hence the apt install.

- [ ] **Step 2: Validate the workflow YAML parses**

Run:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml')); print('YAML OK')"
```

Expected: `YAML OK`.

- [ ] **Step 3: Re-run the local equivalents to confirm green**

Run:

```bash
shellcheck roles/tailscale_sidecar/files/dns-watchdog.sh && \
bats roles/tailscale_sidecar/tests/ && echo "CI EQUIVALENTS PASS"
```

Expected: `... 6 tests, 0 failures` then `CI EQUIVALENTS PASS`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: run shellcheck + bats on the tailscale DNS watchdog

Refs #7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Role variables (defaults + argument_specs)

Declare the new public API. These must be in place before the tasks reference them.

**Files:**
- Modify: `roles/tailscale_sidecar/defaults/main.yml`
- Modify: `roles/tailscale_sidecar/meta/main.yml`

- [ ] **Step 1: Add the defaults**

Append to `roles/tailscale_sidecar/defaults/main.yml` (after the logging block, keeping the file's `---`-led single document):

```yaml
# --- DNS self-heal & upstream watchdog (issue #7) ---
# Upstream DNS servers set on the sidecar container (Docker dns_servers).
# Defaults to MagicDNS so Docker's embedded resolver (127.0.0.11) has a working
# upstream: Docker names -> 127.0.0.11; tailnet/external -> 127.0.0.11 ->
# 100.100.100.100 -> Cloudflare. Set to [] to leave Docker's default wiring.
tailscale_dns_servers:
  - "100.100.100.100"

# Master toggle for the DNS self-heal + upstream watchdog Docker healthcheck.
# Disabling removes BOTH self-heal halves (downstream resolv.conf heal and the
# upstream forwarder watchdog), since Docker allows only one healthcheck.
tailscale_dns_watchdog_enabled: true

# External name + resolver the watchdog probes to detect the empty
# DefaultResolvers SERVFAIL condition. Only used when both
# tailscale_dns_watchdog_enabled and tailscale_accept_dns are true.
tailscale_dns_probe_name: "one.one.one.one"
tailscale_dns_probe_resolver: "100.100.100.100"

# Docker healthcheck cadence for the watchdog.
tailscale_dns_watchdog_interval: "15s"
tailscale_dns_watchdog_timeout: "10s"
tailscale_dns_watchdog_retries: 3
tailscale_dns_watchdog_start_period: "10s"

# Host directory the watchdog script (dns-watchdog.sh) is installed into and
# bind-mounted from. Defaults to a sibling of the state dir so it lands in the
# operator's docker tree (e.g. /volume1/docker/myapp/tailscale-dns-watchdog).
tailscale_dns_watchdog_host_dir: "{{ tailscale_state_dir | dirname }}/tailscale-dns-watchdog"
```

- [ ] **Step 2: Add the argument_specs**

In `roles/tailscale_sidecar/meta/main.yml`, under `argument_specs.main.options`, add these entries (after the existing `tailscale_log_options` entry, same indentation):

```yaml
      tailscale_dns_servers:
        type: list
        elements: str
        default:
          - "100.100.100.100"
        description: >-
          Upstream DNS servers set on the sidecar container (Docker
          dns_servers). Defaults to MagicDNS (100.100.100.100) so Docker's
          embedded resolver (127.0.0.11) has a working upstream. Set to [] to
          leave Docker's default resolver wiring untouched.

      tailscale_dns_watchdog_enabled:
        type: bool
        default: true
        description: >-
          Enable the DNS self-heal + upstream watchdog Docker healthcheck
          (issue #7). Keeps Docker's embedded resolver (127.0.0.11) at the top
          of resolv.conf and, when tailscale_accept_dns is true, detects the
          empty-DefaultResolvers SERVFAIL condition and bounces accept-dns to
          force tailscaled to re-apply DNS. Disabling removes BOTH self-heal
          halves.

      tailscale_dns_probe_name:
        type: str
        default: "one.one.one.one"
        description: >-
          External hostname the watchdog resolves to verify tailscaled's
          forwarder has working upstreams. Only used when
          tailscale_dns_watchdog_enabled and tailscale_accept_dns are true.

      tailscale_dns_probe_resolver:
        type: str
        default: "100.100.100.100"
        description: >-
          Resolver the watchdog queries for tailscale_dns_probe_name (MagicDNS).

      tailscale_dns_watchdog_interval:
        type: str
        default: "15s"
        description: Docker healthcheck interval for the DNS watchdog.

      tailscale_dns_watchdog_timeout:
        type: str
        default: "10s"
        description: Docker healthcheck timeout for the DNS watchdog.

      tailscale_dns_watchdog_retries:
        type: int
        default: 3
        description: >-
          Docker healthcheck retries before the sidecar is reported unhealthy.

      tailscale_dns_watchdog_start_period:
        type: str
        default: "10s"
        description: Docker healthcheck start period before failures count.

      tailscale_dns_watchdog_host_dir:
        type: str
        required: false
        description: >-
          Host directory the watchdog script (dns-watchdog.sh) is installed into
          and bind-mounted from. Defaults (in defaults/main.yml) to a
          tailscale-dns-watchdog sibling of tailscale_state_dir.
```

> Note: `tailscale_dns_watchdog_host_dir` intentionally has **no** `default:` in the argument spec because its default is a Jinja expression resolved in `defaults/main.yml`; declaring a literal default here would not match.

- [ ] **Step 3: Lint to validate the spec structure**

Run:

```bash
uv venv --python 3.12 && uv pip install ansible==14.0.0 ansible-lint==26.4.0
uv run ansible-lint
```

Expected: PASS (no errors; the `var-naming[no-role-prefix]` warning is downgraded by `.ansible-lint`). If ansible-lint reports a YAML or argument_spec structural error, fix it and re-run.

- [ ] **Step 4: Commit**

```bash
git add roles/tailscale_sidecar/defaults/main.yml roles/tailscale_sidecar/meta/main.yml
git commit -m "feat(tailscale_sidecar): add DNS watchdog role variables

Refs #7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire the watchdog into the role tasks

Install the script on the host, bind-mount it into the container, set `dns_servers`, attach the healthcheck, inject the watchdog env vars, and reconcile once after deploy.

**Files:**
- Modify: `roles/tailscale_sidecar/tasks/main.yml`

- [ ] **Step 1: Add the host-side script install (before the container is deployed)**

In `roles/tailscale_sidecar/tasks/main.yml`, insert these two tasks immediately **after** the `Create Tailscale state directory` task and **before** `Create Tailscale Serve config directory`:

```yaml
- name: Create DNS watchdog script directory on the host
  ansible.builtin.file:
    path: "{{ tailscale_dns_watchdog_host_dir }}"
    state: directory
    mode: "0755"
  when: tailscale_dns_watchdog_enabled

- name: Install the DNS watchdog script on the host
  ansible.builtin.copy:
    src: dns-watchdog.sh
    dest: "{{ tailscale_dns_watchdog_host_dir }}/dns-watchdog.sh"
    mode: "0755"
  when: tailscale_dns_watchdog_enabled
```

- [ ] **Step 2: Add `dns_servers` and the `healthcheck` to the container task**

In the `Deploy Tailscale sidecar container` task (`community.docker.docker_container`), add these two keys. Put them right after the `restart_policy: always` line:

```yaml
    dns_servers: "{{ tailscale_dns_servers if (tailscale_dns_servers | length > 0) else omit }}"
    healthcheck: >-
      {{
        {
          'test': ['CMD', '/bin/sh', '/usr/local/bin/dns-watchdog.sh'],
          'interval': tailscale_dns_watchdog_interval,
          'timeout': tailscale_dns_watchdog_timeout,
          'retries': tailscale_dns_watchdog_retries,
          'start_period': tailscale_dns_watchdog_start_period,
        }
        if tailscale_dns_watchdog_enabled else omit
      }}
```

> Why `/bin/sh /usr/local/bin/...` and not the script directly: invoking via `sh` is robust even if the bind-mounted file's exec bit is ever lost. The healthcheck inherits the container's environment, so the `TS_DNS_*` vars added in Step 4 are visible.

- [ ] **Step 3: Extend the container `volumes` to bind-mount the script**

In the same task, the current `volumes` expression ends with the serve-config conditional. Replace the whole `volumes:` value with this version (adds the watchdog mount as a `:ro` single-file bind):

```yaml
    volumes: >-
      {{
        [
          tailscale_state_dir ~ ':/var/lib/tailscale',
          '/dev/net/tun:/dev/net/tun',
        ]
        + (
            [tailscale_serve_config_dir ~ ':/etc/tailscale:ro']
            if tailscale_serve_enabled else []
          )
        + (
            [tailscale_dns_watchdog_host_dir ~ '/dns-watchdog.sh:/usr/local/bin/dns-watchdog.sh:ro']
            if tailscale_dns_watchdog_enabled else []
          )
      }}
```

- [ ] **Step 4: Inject the watchdog env vars**

In the same task, the current `env:` value is a `combine()` chain. Add one more `combine()` to the end of that chain (immediately before the closing `}}`), so the script receives its configuration:

```yaml
        | combine(
            {
              'TS_DNS_ACCEPT_DNS': tailscale_accept_dns | string | lower,
              'TS_DNS_PROBE_NAME': tailscale_dns_probe_name,
              'TS_DNS_PROBE_RESOLVER': tailscale_dns_probe_resolver,
            }
            if tailscale_dns_watchdog_enabled else {}
          )
```

For reference, the full `env:` value after this edit is:

```yaml
    env: >-
      {{
        {
          'TS_HOSTNAME': tailscale_hostname,
          'TS_AUTHKEY': tailscale_authkey,
          'TS_STATE_DIR': '/var/lib/tailscale',
          'TS_USERSPACE': 'false',
          'TS_ACCEPT_DNS': tailscale_accept_dns | string | lower,
        }
        | combine(
            {'TS_SERVE_CONFIG': '/etc/tailscale/serve.json'}
            if tailscale_serve_enabled else {}
          )
        | combine(
            {'TS_EXTRA_ARGS': tailscale_extra_args}
            if tailscale_extra_args else {}
          )
        | combine(
            {
              'TS_DNS_ACCEPT_DNS': tailscale_accept_dns | string | lower,
              'TS_DNS_PROBE_NAME': tailscale_dns_probe_name,
              'TS_DNS_PROBE_RESOLVER': tailscale_dns_probe_resolver,
            }
            if tailscale_dns_watchdog_enabled else {}
          )
      }}
```

- [ ] **Step 5: Add the post-deploy reconcile task (after the container is Running)**

Append this task to the **end** of `roles/tailscale_sidecar/tasks/main.yml`, after `Wait for Tailscale to connect to tailnet`:

```yaml
- name: Reconcile sidecar DNS immediately after (re)deploy
  # Runs the watchdog once at deploy time so DNS converges immediately instead
  # of waiting up to one healthcheck start_period. Non-blocking: failures are
  # ignored here (failed_when: false) because the healthcheck keeps
  # reconciling on its interval — a transient miss must not fail the play that
  # fronts tier-1 services.
  community.docker.docker_container_exec:
    container: "{{ tailscale_container_name }}"
    command: /bin/sh /usr/local/bin/dns-watchdog.sh
  changed_when: false
  failed_when: false
  when:
    - tailscale_dns_watchdog_enabled
    - not ansible_check_mode
```

- [ ] **Step 6: Lint and syntax-check the role**

Run:

```bash
uv run ansible-lint
```

Expected: PASS. ansible-lint parses `tasks/main.yml`; fix any reported issues (e.g. jinja spacing, FQCN) and re-run.

- [ ] **Step 7: Static-render check of the new Jinja expressions**

Create a throwaway check playbook so the new `healthcheck`/`volumes`/`env` expressions are templated against real values (no Docker calls needed — this only validates the templating + var wiring, run in check mode):

```bash
cat > /tmp/ts-watchdog-check.yml <<'YAML'
- hosts: localhost
  gather_facts: false
  vars:
    tailscale_container_name: ts-check
    tailscale_hostname: ts-check
    tailscale_authkey: "tskey-fake"
    tailscale_state_dir: /tmp/ts-check/state
    tailscale_network_name: ts-check-net
  roles:
    - role: jaxzin.infra.tailscale_sidecar
YAML

ANSIBLE_ROLES_PATH= uv run ansible-playbook /tmp/ts-watchdog-check.yml \
  --syntax-check -i localhost,
```

Expected: `playbook: /tmp/ts-watchdog-check.yml` with no syntax errors. (Running it for real requires Docker + a valid tailnet auth key — that is covered by the manual runbook in Task 6, not here.) Clean up: `rm /tmp/ts-watchdog-check.yml`.

> If the collection is not installed under the configured collections path, run the syntax-check from a context where `jaxzin.infra` resolves (e.g. `ansible-galaxy collection install . ` into a temp path, or run from the collection's parent `ansible_collections/jaxzin/infra` layout). The goal is only to confirm the role's YAML + Jinja parse.

- [ ] **Step 8: Commit**

```bash
git add roles/tailscale_sidecar/tasks/main.yml
git commit -m "feat(tailscale_sidecar): run DNS watchdog as the sidecar healthcheck

Install dns-watchdog.sh on the host, bind-mount it into the sidecar, set
dns_servers to MagicDNS, attach it as the container healthcheck, inject
its config via TS_DNS_* env, and reconcile once after deploy.

Refs #7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Documentation + build_ignore

Document the new behavior/variables and keep the bats tests out of the published tarball.

**Files:**
- Modify: `roles/tailscale_sidecar/README.md`
- Modify: `galaxy.yml`

- [ ] **Step 1: Add a README section for the watchdog**

In `roles/tailscale_sidecar/README.md`, add a new subsection after the existing `### DNS` table (before `### Logging`):

```markdown
### DNS self-heal & upstream watchdog

In kernel-mode + shared-netns deployments, `tailscaled` can finish startup
without applying the tailnet DNS config to its forwarder (`DefaultResolvers`
ends up empty), so MagicDNS (`100.100.100.100`) returns **SERVFAIL for every
query** and all outbound DNS in the shared netns breaks silently — while the
serve/funnel path keeps working. See
[issue #7](https://github.com/jaxzin/ansible-collection-infra/issues/7).

The role installs a healthcheck script (`dns-watchdog.sh`) on the sidecar that,
on each interval:

1. **Downstream heal** — re-prepends Docker's embedded resolver (`127.0.0.11`)
   to `/etc/resolv.conf` so containers sharing this netns keep resolving Docker
   service names (tailscaled strips it on every restart).
2. **Upstream watchdog** — when `tailscale_accept_dns` is `true`, probes an
   external name against MagicDNS; if it SERVFAILs, it bounces
   `accept-dns` false→true to force tailscaled to re-apply its DNS config
   (verified non-disruptive). After the bounce it re-probes and reports the
   container `unhealthy` only if DNS is still broken — informational only, since
   `restart_policy: always` does not restart unhealthy containers.

| Variable | Default | Description |
|----------|---------|-------------|
| `tailscale_dns_watchdog_enabled` | `true` | Enable the self-heal + watchdog healthcheck. Disabling removes both halves. |
| `tailscale_dns_servers` | `["100.100.100.100"]` | Container `dns_servers`; gives `127.0.0.11` a working upstream. `[]` leaves Docker's default. |
| `tailscale_dns_probe_name` | `one.one.one.one` | External name the watchdog resolves. |
| `tailscale_dns_probe_resolver` | `100.100.100.100` | Resolver the watchdog queries. |
| `tailscale_dns_watchdog_interval` | `15s` | Healthcheck interval. |
| `tailscale_dns_watchdog_timeout` | `10s` | Healthcheck timeout. |
| `tailscale_dns_watchdog_retries` | `3` | Failures before reported unhealthy. |
| `tailscale_dns_watchdog_start_period` | `10s` | Grace period before failures count. |
| `tailscale_dns_watchdog_host_dir` | `<state_dir>/../tailscale-dns-watchdog` | Host dir the script is installed into and mounted from. |
```

- [ ] **Step 2: Exclude the bats tests from the published collection**

In `galaxy.yml`, add one entry to the `build_ignore` list:

```yaml
  - roles/tailscale_sidecar/tests
```

(The `files/` directory is **not** ignored — `dns-watchdog.sh` must ship so the role's `copy` task finds it at runtime.)

- [ ] **Step 3: Verify the build includes the script but excludes the tests**

Run:

```bash
uv run ansible-galaxy collection build --output-path /tmp/ts-build --force
tar tzf /tmp/ts-build/jaxzin-infra-*.tar.gz | grep -E 'dns-watchdog' || echo "MISSING SCRIPT"
```

Expected: `roles/tailscale_sidecar/files/dns-watchdog.sh` is listed, and `roles/tailscale_sidecar/tests/dns-watchdog.bats` is **absent**. Clean up: `rm -rf /tmp/ts-build`.

- [ ] **Step 4: Final ansible-lint**

Run: `uv run ansible-lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add roles/tailscale_sidecar/README.md galaxy.yml
git commit -m "docs(tailscale_sidecar): document DNS watchdog; exclude tests from build

Refs #7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Full verification + manual runbook

Confirm everything is green and capture the one path that cannot be unit-tested (real Docker + tailnet behavior) as a runbook.

- [ ] **Step 1: Run the complete local verification suite**

Run:

```bash
shellcheck roles/tailscale_sidecar/files/dns-watchdog.sh && \
bats roles/tailscale_sidecar/tests/ && \
uv run ansible-lint && \
echo "ALL LOCAL CHECKS PASS"
```

Expected: `6 tests, 0 failures`, ansible-lint clean, then `ALL LOCAL CHECKS PASS`. Do not proceed until this prints.

- [ ] **Step 2: Manual end-to-end verification (real deploy)**

This validates the behavior the unit tests stub out. Run against a real target host with a valid `TS_AUTHKEY`:

1. Deploy the role to a kernel-mode, shared-netns sidecar (`tailscale_accept_dns: true`).
2. Confirm the healthcheck is attached and passing:
   ```bash
   docker inspect --format '{{json .State.Health}}' <sidecar> | python3 -m json.tool
   ```
   Expected: `Status: healthy` once the start period elapses.
3. Confirm both halves of the chain resolve from inside the netns:
   ```bash
   docker exec <sidecar> nslookup one.one.one.one 100.100.100.100   # external
   docker exec <sidecar> sh -c 'head -n1 /etc/resolv.conf'          # 127.0.0.11
   ```
4. **Simulate the bug** and confirm recovery: force an empty-forwarder state by restarting tailscaled (`docker restart <sidecar>`), then within ~2 healthcheck intervals re-run the external `nslookup` and confirm it resolves (the watchdog should have bounced accept-dns). Check the logs for the bounce.

Record the outcome in the PR description.

- [ ] **Step 3: Push the branch and open the PR**

```bash
git push -u origin "$(git branch --show-current)"
gh pr create --title "fix(tailscale_sidecar): self-heal DNS so tailscaled's empty DefaultResolvers can't break the netns" \
  --body "$(cat <<'BODY'
Adds a DNS self-heal + upstream watchdog healthcheck to the sidecar so a
tailscaled boot with empty DefaultResolvers can no longer silently break all
outbound DNS in the shared network namespace.

- `dns-watchdog.sh` (bats-tested): resolv.conf heal + MagicDNS probe + accept-dns
  bounce. Runs as the container healthcheck; reports unhealthy only if DNS is
  still broken after a bounce (informational; non-disruptive).
- New `tailscale_dns_*` variables; `dns_servers` wired to MagicDNS.
- shellcheck + bats CI jobs.

Manual end-to-end verification: <fill in Step 2 results>.

Closes #7

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

> Conventional-commit note: the PR title / squash-merge subject drives semantic-release. `fix(tailscale_sidecar): …` cuts a patch; the work also adds variables (a `feat`), so if you prefer a minor bump use `feat(tailscale_sidecar): …`. **Never** put a literal `[skip ci]` in any commit/PR text (it disables all GitHub Actions for that commit). Do **not** hand-edit `CHANGELOG.md` — semantic-release owns it.

---

## Self-Review

**Spec coverage (issue #7):**
- "Upstream-DNS watchdog … bounce accept-dns (false→true) to force re-application" → Task 1 (`bounce_accept_dns`), Task 4 (healthcheck wiring). ✅
- "Must be non-blocking (this sidecar fronts tier-1 services)" → unhealthy is informational (no restart under `restart_policy: always`); post-deploy reconcile is `failed_when: false`. ✅
- "Fold the check into … a healthcheck (it already runs on an interval)" → single Docker healthcheck runs `dns-watchdog.sh`. ✅
- "bring the downstream resolv.conf self-heal … into this collection role so both halves live in one canonical place" → `heal_resolv_conf` in the same script. ✅
- `dns_servers` wiring that makes the chain work → Task 3/4 (`tailscale_dns_servers`). ✅
- Out-of-scope items (auth-key assertions, userspace mode, the "Override local DNS" tailnet alternative) → deliberately excluded; noted as a follow-up. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code and command step contains the full content. ✅

**Type/name consistency:** Variable names are identical across defaults, argument_specs, tasks, README, and the script's env contract: `tailscale_dns_servers`, `tailscale_dns_watchdog_enabled`, `tailscale_dns_probe_name`, `tailscale_dns_probe_resolver`, `tailscale_dns_watchdog_{interval,timeout,retries,start_period}`, `tailscale_dns_watchdog_host_dir`. The script env keys (`TS_DNS_ACCEPT_DNS`, `TS_DNS_PROBE_NAME`, `TS_DNS_PROBE_RESOLVER`, `RESOLV_CONF`, `TS_DNS_BOUNCE_SETTLE`) match between `dns-watchdog.sh`, the bats `setup()`, and the role `env:` block. Mount path `/usr/local/bin/dns-watchdog.sh` is identical in the `volumes`, `healthcheck`, and reconcile task. ✅

---

## Execution Deviations

Executed via the team-plan-execution skill (oversight team: architect, TPM, SDET, security, tech-writer, devops-SRE). The following refinements emerged from review and deviate from the verbatim plan above — all in-scope for the DNS fix, all with the bats suite still green (6/6):

- **`dns-watchdog.sh` — observability:** `bounce_accept_dns()` now emits `dns-watchdog: upstream SERVFAIL detected; bouncing accept-dns to force re-apply` to **stderr** before the bounce (→ `docker logs`). Closes a gap where Task 6's runbook said "check the logs for the bounce" but nothing logged. (commit `7bbdc6f`)
- **`dns-watchdog.sh` — timeout budget:** probe `timeout 3` → `timeout 2`, keeping the worst-case bounce-path runtime (~6s) safely under the 10s healthcheck timeout while the interval stays 15s. (commit `7bbdc6f`)
- **`dns-watchdog.bats`:** two assertions added — the bounce log line appears on the repair path, and the `--accept-dns=true` restore leg runs even when the bounce doesn't repair. Still 6 tests. (commit `7bbdc6f`)
- **`meta/main.yml`:** dropped the redundant `required: false` on `tailscale_dns_watchdog_host_dir` (only such occurrence; house style omits it) and expanded the `tailscale_dns_probe_resolver` description to house style. (commit `da6c2df`)
- **`README.md`:** `tailscale_dns_watchdog_host_dir` default rendered as "sibling of `tailscale_state_dir` (…/tailscale-dns-watchdog)" instead of the awkward `<state_dir>/../…`. (commit `b94378b`)
- **`tasks/main.yml`:** the `TS_DNS_ACCEPT_DNS` vs `TS_ACCEPT_DNS` dual-key note is a YAML comment on the `env:` key line — a `#` inside the `>-` Jinja scalar is invalid and a `{# #}` failed ansible-lint. (commit `9ece99d`)

**Deferred (out of scope, follow-up issue):** the existing "Wait for Tailscale to connect" task has no `failed_when: false`, so a never-Running sidecar fails the play before the reconcile task. This matches the bootstrap copy's auth-key-assertion gap and is part of the deferred auth-key/userspace parity work, not this DNS fix.
