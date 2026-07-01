#!/usr/bin/env bash
# reconcile_selftest.sh — self-test for stack_reconcile.sh (Task 1, Step 3).
#
# Renders the Jinja2 template to a plain POSIX script (the go-template guards
# {{ "{{.X}}" }} collapse to literal {{.X}}), stubs `docker` / `date` / `wget`
# on PATH so the script runs with NO real Docker daemon and NO network, then
# asserts each reconcile case with REAL side-effect assertions: the exact
# expected `docker start`/`restart <name>` action(s) must be present AND, for
# positive cases, the action log must match exactly (no unexpected actions).
#
# Cases:
#   (a) maintenance lock present          -> no action
#   (b) exited + always + aged            -> start gitea-db (exact log)
#   (c) all running                       -> no action
#   (d) exited but younger than debounce  -> no start
#   (e) dep healthy + gate unhealthy      -> restart gitea (exact log)
#   (f) no-such-container                 -> skip gracefully, no action, rc 0
#   (g) age unknown (FinishedAt zero)     -> revive + "age unknown" log line
#   (i) dep NOT healthy + gate unhealthy  -> NO restart (dep-health load-bearing)
#   thrash-guard: dep healthy + gate starting -> NO restart (excludes "starting")
#   policy != always (exited+aged)        -> NO start (restart-policy load-bearing)
#   (j) ENSURE self-revive                -> start stack-reconcile
#   (k) Discord alert                     -> wget stub records a POST
#
# The fake `docker` answers `inspect -f <fmt> <name>` from a per-case state
# table and records `start`/`restart` invocations to a marker file, so each
# assertion just greps the marker. Exit 0 only when ALL cases pass.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/playbooks/roles/stack_reconcile/templates/stack_reconcile.sh.j2"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Render the template to a runnable POSIX script ------------------------
SCRIPT="$WORK/stack_reconcile.sh"
python3 - "$TEMPLATE" > "$SCRIPT" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
t = re.sub(r'\{\{\s*"(.*?)"\s*\}\}', r'\1', t)   # {{ "{{.X}}" }} -> {{.X}}
sys.stdout.write(t)
PY
chmod +x "$SCRIPT"

# --- Fake `docker` on PATH -------------------------------------------------
# State is passed via files in $STATE_DIR (one file per "container.field").
# The stub answers `docker inspect -f '<go-template>' <name>` by mapping the
# template string to a field name and reading <name>.<field> from disk.
# A MISSING <name>.status file means "no such container": every field for that
# name returns rc=1/empty, mirroring real docker for an unknown container.
# `docker start`/`docker restart` append "<verb> <name>" to $ACTIONS.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
STATE_DIR="$WORK/state"
ACTIONS="$WORK/actions.log"

cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
# Minimal docker stub: inspect / start / restart only.
set -u
verb="$1"; shift
case "$verb" in
  inspect)
    # args: -f <format> <name>
    fmt=""; name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f) fmt="$2"; shift 2 ;;
        *)  name="$1"; shift ;;
      esac
    done
    case "$fmt" in
      *".State.Status"*)                  field="status" ;;
      *".HostConfig.RestartPolicy.Name"*) field="policy" ;;
      *".State.FinishedAt"*)              field="finished" ;;
      *".State.Health"*)                  field="health" ;;
      *)                                   field="unknown" ;;
    esac
    f="$STATE_DIR/$name.$field"
    if [ -f "$f" ]; then
      cat "$f"
    else
      # No such container/field: emit nothing, non-zero (mirrors real docker).
      exit 1
    fi
    ;;
  start)   echo "start $1" >> "$ACTIONS" ;;
  restart) echo "restart $1" >> "$ACTIONS" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/docker"
export STATE_DIR ACTIONS

# --- Fake `date` on PATH ---------------------------------------------------
# The production script parses Docker's FinishedAt with GNU `date -d <rfc3339>`
# (host cron) and busybox `date -D ... -d` (Alpine watchdog). This test host
# may be macOS/BSD, where NEITHER form works — which would push every case
# through the script's "age unknown -> start anyway" branch and make the
# debounce cases (b)/(d) untestable. So we shim BOTH forms via python3 and pass
# every other invocation through to the real `date`:
#   * GNU form:     date -u -d "<str>" +%s
#   * busybox form: date -u -D '<infmt>' -d "<str>" +%s
# By default the GNU form is exercised. Set DATE_FORCE_BUSYBOX=1 to make the
# GNU form FAIL (return non-zero) so the script falls through to the busybox
# `-D` branch — that lets at least one debounce case exercise the real
# busybox parse path the Alpine watchdog actually uses.
#
# Both forms accept a fractional RFC3339Nano (".NNNNNNNNNZ"); the production
# script strips the fraction with `sed 's/\.[0-9]*Z$/Z/'` before calling date,
# but the shim tolerates a leftover fraction too so the test is robust.
REAL_DATE="$(command -v date)"
export REAL_DATE
cat > "$STUB_BIN/date" <<'DSTUB'
#!/usr/bin/env bash
set -u
parse() {
  # $1 = rfc3339[.frac]Z string -> epoch on stdout, rc reflects success.
  python3 - "$1" <<'PY'
import sys, calendar, time, re
s = sys.argv[1]
# tolerate an optional fractional second and trailing Z
s = re.sub(r'\.[0-9]+', '', s).rstrip("Z")
t = time.strptime(s, "%Y-%m-%dT%H:%M:%S")
print(calendar.timegm(t))
PY
}
# GNU form:  date -u -d "<str>" +%s
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "-d" ] && [ "${4:-}" = "+%s" ]; then
  if [ "${DATE_FORCE_BUSYBOX:-0}" = "1" ]; then exit 1; fi   # force fall-through
  parse "$3"; exit $?
fi
# busybox form:  date -u -D '<infmt>' -d "<str>" +%s
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "-D" ] && [ "${4:-}" = "-d" ] && [ "${6:-}" = "+%s" ]; then
  parse "$5"; exit $?
fi
exec "$REAL_DATE" "$@"
DSTUB
chmod +x "$STUB_BIN/date"

# --- Fake `wget` on PATH ---------------------------------------------------
# The production alert() POSTs to the Discord webhook with
#   wget -q -T 5 -O /dev/null --post-data=<body> --header=... <url>
# Record every invocation (including the --post-data body) so case (k) can
# assert a POST actually happened with the expected JSON content.
WGET_LOG="$WORK/wget.log"
export WGET_LOG
cat > "$STUB_BIN/wget" <<'WSTUB'
#!/usr/bin/env bash
set -u
{
  echo "wget-called"
  for a in "$@"; do echo "$a"; done
} >> "$WGET_LOG"
exit 0
WSTUB
chmod +x "$STUB_BIN/wget"

PATH="$STUB_BIN:$PATH"
export PATH

# --- helpers ---------------------------------------------------------------
PASS=0
FAIL=0

reset_state() {
  rm -rf "$STATE_DIR" "$ACTIONS" "$WGET_LOG"
  mkdir -p "$STATE_DIR"
  : > "$ACTIONS"
  : > "$WGET_LOG"
  # Clear per-case overrides. POSIX keeps a `VAR=x func` prefix assignment set
  # in the CURRENT shell after the function returns (unlike a prefix on an
  # external command), so without this an earlier case's RC_LOCK/RC_GATE would
  # silently leak into later cases. Reset them every case to stay isolated.
  RC_CONTAINERS=""; RC_GATE=""; RC_GATE_DEP=""; RC_LOCK=""; RC_DEBOUNCE=""
  RC_ENSURE=""; RC_HOOK=""
  # Same prefix-leak caveat: DATE_FORCE_BUSYBOX set as a prefix on the
  # run_reconcile function call stays in this shell, so clear it each case.
  DATE_FORCE_BUSYBOX=0
}

# set_container <name> <status> <policy> <finished-rfc3339|-> [health]
set_container() {
  name="$1"; status="$2"; policy="$3"; finished="$4"; health="${5:-}"
  printf '%s' "$status"   > "$STATE_DIR/$name.status"
  printf '%s' "$policy"   > "$STATE_DIR/$name.policy"
  if [ "$finished" = "-" ]; then
    printf '%s' "0001-01-01T00:00:00Z" > "$STATE_DIR/$name.finished"
  else
    printf '%s' "$finished" > "$STATE_DIR/$name.finished"
  fi
  # health field mirrors the go-template `{{if .State.Health}}...{{end}}`:
  # empty string when the container has no healthcheck.
  printf '%s' "$health" > "$STATE_DIR/$name.health"
}

# An RFC3339Nano timestamp `age` seconds in the past, WITH a fractional
# `.NNNNNNNNNZ` (9-digit) part — exactly what Docker's FinishedAt looks like —
# so the production script's `sed 's/\.[0-9]*Z$/Z/'` fraction-strip is exercised
# on a real value. Computed with python3 so it is identical on GNU and BSD hosts
# and independent of the `date` stub above.
ago() {
  python3 - "$1" <<'PY'
import sys, time
base = time.gmtime(time.time() - int(sys.argv[1]))
# emit fractional nanoseconds (RFC3339Nano) like docker does
print(time.strftime("%Y-%m-%dT%H:%M:%S", base) + ".123456789Z")
PY
}

run_reconcile() {
  # Common env; callers override RECONCILE_LOCK etc. as needed.
  # DATE_FORCE_BUSYBOX is passed through explicitly so it reaches the `date`
  # stub subprocess (a bare prefix on this function call would set it only in
  # the current shell, never exported into `sh "$SCRIPT"`).
  RECONCILE_CONTAINERS="${RC_CONTAINERS:-gitea-db gitea}" \
  RECONCILE_GATE="${RC_GATE:-}" \
  RECONCILE_GATE_DEPENDS_ON="${RC_GATE_DEP:-}" \
  RECONCILE_LOCK="${RC_LOCK:-$WORK/nonexistent.lock}" \
  RECONCILE_DEBOUNCE="${RC_DEBOUNCE:-90}" \
  RECONCILE_ENSURE_CONTAINER="${RC_ENSURE:-}" \
  RECONCILE_LOG="$WORK/reconcile.log" \
  RECONCILE_DISCORD_WEBHOOK="${RC_HOOK:-}" \
  DATE_FORCE_BUSYBOX="${DATE_FORCE_BUSYBOX:-0}" \
  DOCKER_BIN="docker" \
  sh "$SCRIPT"
}

check() {
  desc="$1"; cond="$2"
  if [ "$cond" = "ok" ]; then
    PASS=$(( PASS + 1 )); printf '  PASS: %s\n' "$desc"
  else
    FAIL=$(( FAIL + 1 )); printf '  FAIL: %s\n' "$desc"
    printf '        actions were:\n'; sed 's/^/          /' "$ACTIONS" 2>/dev/null || true
  fi
}

# An action is PRESENT (line-exact) in the log.
actions_contain() { grep -qxF "$1" "$ACTIONS" 2>/dev/null && echo ok || echo no; }
# The log is empty (no actions at all).
actions_empty()   { [ ! -s "$ACTIONS" ] && echo ok || echo no; }
# The log contains EXACTLY the given action and nothing else (one line).
# This is the "no unexpected actions" guard for positive cases.
actions_exact() {
  want="$1"
  n="$(grep -c . "$ACTIONS" 2>/dev/null || echo 0)"
  if [ "$n" = "1" ] && [ "$(actions_contain "$want")" = ok ]; then echo ok; else echo no; fi
}
# A substring is present in the reconcile LOG (not the action log).
log_contains() { grep -qF "$1" "$WORK/reconcile.log" 2>/dev/null && echo ok || echo no; }
# The wget stub recorded a call AND saw the given substring among its args.
wget_posted() {
  [ -s "$WGET_LOG" ] || { echo no; return; }
  grep -qF "wget-called" "$WGET_LOG" 2>/dev/null || { echo no; return; }
  grep -qF "$1" "$WGET_LOG" 2>/dev/null && echo ok || echo no
}

# --- (a) maintenance lock present -> no start ------------------------------
reset_state
set_container gitea-db exited always "$(ago 9999)"
set_container gitea    exited always "$(ago 9999)"
LOCK_FILE="$WORK/present.lock"; : > "$LOCK_FILE"
RC_LOCK="$LOCK_FILE" run_reconcile
check "(a) maintenance lock present -> no docker start" "$(actions_empty)"

# --- (b) exited + always + aged past debounce -> start (exact) -------------
# Force the busybox `date -D` parse path so the watchdog's ACTUAL Alpine
# parse branch is exercised in a debounce case (GNU form is made to fail).
reset_state
set_container gitea-db exited always "$(ago 600)"
set_container gitea    running always "$(ago 600)"
DATE_FORCE_BUSYBOX=1 RC_DEBOUNCE=90 run_reconcile
check "(b) aged orphan -> exactly 'start gitea-db' (busybox date -D path)" \
  "$(actions_exact 'start gitea-db')"
# Prove the busybox -D parse actually RESOLVED an epoch: gitea-db must NOT have
# gone through the "age unknown" branch (which would also start it). If the
# busybox path silently failed, the age would be unknown and this would catch it.
check "(b) busybox path resolved age (no 'gitea-db' age-unknown)" \
  "$( grep -F "age unknown" "$WORK/reconcile.log" 2>/dev/null | grep -qF "gitea-db" && echo no || echo ok )"

# --- (c) running -> no-op --------------------------------------------------
reset_state
set_container gitea-db running always "-"
set_container gitea    running always "-"
run_reconcile
check "(c) all running -> no start/restart" "$(actions_empty)"

# --- (d) exited but younger than debounce -> no start ----------------------
reset_state
set_container gitea-db exited always "$(ago 10)"
set_container gitea    running always "$(ago 10)"
RC_DEBOUNCE=90 run_reconcile
check "(d) within debounce -> no docker start" \
  "$( [ "$(actions_contain 'start gitea-db')" = no ] && [ "$(actions_empty)" = ok ] && echo ok || echo no )"

# --- (e) dep healthy + gate unhealthy -> restart gate (exact) --------------
reset_state
# Both running so step 2 never starts them; gate is running+unhealthy,
# dep is running+healthy -> step 3 should restart the gate exactly once.
set_container gitea-db running always "-" healthy
set_container gitea    running always "-" unhealthy
RC_GATE="gitea" RC_GATE_DEP="gitea-db" run_reconcile
check "(e) dep healthy + gate unhealthy -> exactly 'restart gitea'" \
  "$(actions_exact 'restart gitea')"

# --- (f) no-such-container -> skip gracefully, no action, exit 0 -----------
reset_state
# Only gitea-db has state; "gitea" has NO state files -> inspect returns
# rc=1/empty -> script logs "no such container" and skips. gitea-db is running
# so it produces no action either. Whole run must be a clean no-op, rc 0.
set_container gitea-db running always "-"
# (deliberately do NOT set_container gitea)
run_reconcile; rc=$?
check "(f) no-such-container -> no action" "$(actions_empty)"
check "(f) no-such-container -> exit 0" "$( [ "$rc" -eq 0 ] && echo ok || echo no )"
check "(f) no-such-container -> 'no such container' logged" "$(log_contains "no such container 'gitea'")"

# --- (g) age unknown (FinishedAt zero) -> revive + 'age unknown' log --------
reset_state
# exited + always + FinishedAt "0001-01-01..." (the "-" sentinel) -> age can't
# be computed -> script must skip debounce and start anyway, logging the
# distinctive "age unknown" line.
set_container gitea-db exited always "-"
set_container gitea    running always "-"
run_reconcile
check "(g) age unknown -> exactly 'start gitea-db'" "$(actions_exact 'start gitea-db')"
check "(g) age unknown -> 'age unknown' log line present" "$(log_contains "age unknown")"

# --- (i) dep NOT healthy + gate unhealthy -> NO restart --------------------
reset_state
# dep is running but UNHEALTHY; gate is running+unhealthy. The dep-health
# guard is load-bearing: a mutant that ignores dep health would restart the
# gate here and FAIL this case.
set_container gitea-db running always "-" unhealthy
set_container gitea    running always "-" unhealthy
RC_GATE="gitea" RC_GATE_DEP="gitea-db" run_reconcile
check "(i) dep NOT healthy -> NO restart of gate" \
  "$( [ "$(actions_contain 'restart gitea')" = no ] && [ "$(actions_empty)" = ok ] && echo ok || echo no )"

# --- thrash-guard: dep healthy + gate 'starting' -> NO restart -------------
reset_state
# gate is running but still in healthcheck start_period ("starting"). The
# condition keys on gate_h == "unhealthy", NOT "!= healthy", so "starting"
# must be left alone — restarting would reset start_period and thrash gitea.
set_container gitea-db running always "-" healthy
set_container gitea    running always "-" starting
RC_GATE="gitea" RC_GATE_DEP="gitea-db" run_reconcile
check "(thrash-guard) gate 'starting' -> NO restart" \
  "$( [ "$(actions_contain 'restart gitea')" = no ] && [ "$(actions_empty)" = ok ] && echo ok || echo no )"

# --- policy != always (exited + aged) -> NO start --------------------------
reset_state
# Aged past debounce, exited — but restart policy is "no". The restart-policy
# guard is load-bearing: a mutant dropping it would start this and FAIL.
set_container gitea-db exited no "$(ago 600)"
set_container gitea    running always "-"
RC_DEBOUNCE=90 run_reconcile
check "(policy!=always) exited+aged but restart=no -> NO start" \
  "$( [ "$(actions_contain 'start gitea-db')" = no ] && [ "$(actions_empty)" = ok ] && echo ok || echo no )"

# --- (j) ENSURE self-revive ------------------------------------------------
reset_state
# RECONCILE_ENSURE_CONTAINER names the watchdog itself; it is exited, so step 1
# must `start` it. Use a CONTAINERS list that is all-running so the only action
# is the ENSURE start.
set_container stack-reconcile exited always "-"
set_container gitea-db        running always "-"
set_container gitea           running always "-"
RC_ENSURE="stack-reconcile" run_reconcile
check "(j) ENSURE self-revive -> exactly 'start stack-reconcile'" \
  "$(actions_exact 'start stack-reconcile')"

# --- (k) Discord alert -> wget POST recorded -------------------------------
reset_state
# Trigger a start action with a webhook configured; alert() must invoke the
# wget stub with the JSON body. Assert the stub recorded a call carrying the
# expected content marker.
set_container gitea-db exited always "$(ago 600)"
set_container gitea    running always "$(ago 600)"
RC_DEBOUNCE=90 RC_HOOK="http://discord.invalid/webhook" run_reconcile
check "(k) Discord alert -> wget POST recorded" \
  "$(wget_posted '[stack_reconcile]')"
check "(k) Discord alert -> action still taken (start gitea-db)" \
  "$(actions_contain 'start gitea-db')"

# --- summary ---------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: $PASS/$TOTAL cases passed"
  exit 0
else
  echo "FAILED: $PASS/$TOTAL cases passed ($FAIL failed)"
  exit 1
fi
