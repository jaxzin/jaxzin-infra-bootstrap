# Tailscale Sidecar Auth-Key Fail-Fast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a deploy fail immediately with an actionable, auth-aware error when the persistent Tailscale sidecar's `TS_AUTHKEY` is expired/revoked or the sidecar is "registered but not routing", instead of an opaque 60 s timeout that surfaces as `ENETUNREACH` four Ansible plays later in downstream consumer deploys.

**Architecture:** This repo has **no per-job ephemeral Tailscale nodes** (Gitea issue #25's stated mechanism does not exist here — confirmed: stock `gitea/act_runner:0.2.12-dind`, no `tailscale up`/`--authkey` in any tracked file). Jobs reach the tailnet via the **persistent userspace `tailscale-runner` sidecar** (`HTTPS_PROXY`/`ALL_PROXY` injected through `gitea_runner_proxy_env`). Both sidecars authenticate with one persistent `TS_AUTHKEY` (CI secret → `playbooks/vars/main.yml:19` → `tailscale_sidecar` role env). The only readiness gate is the "Wait for Tailscale to connect to tailnet" task (`playbooks/roles/tailscale_sidecar/tasks/main.yml:74-85`): it polls `BackendState == "Running"` for 60 s then fails with a generic Ansible `until` timeout — no auth-failure detection, and `Running` ≠ a usable route. The fix adds an auth-aware fail-fast + a real route assertion to that role, a TDD static lock-in (Check G, same idiom as the just-shipped Check F for #96), and an operator rotation runbook (the key mint itself is inherently a Tailscale-console operator action; everything else is idempotent IaC).

**Tech Stack:** Ansible (`community.docker.docker_container_exec`, `assert`, `fail`, `set_fact`), `tailscale status --json`, Python 3 stdlib (`tests/check_docker_tasks.py`), `tests/test-regression.yml`, GitHub Actions + Gitea Actions (`bootstrap`/`deploy` via `common-bootstrap.yml`), `gh` CLI.

---

## Background (Gitea issue #25, re-scoped)

#25's **symptom analysis is correct** (last green 2026-05-10; "registered ≠ routing"; `ENETUNREACH` to a verifiably-healthy host; progressive degradation; blocks the obsidian-mcp deploy chain → wedged `vault-sync` → claude.ai can't write the Obsidian vault). Its **mechanism attribution is wrong for this repo**: there is no per-job ephemeral node and no per-job authkey. The architecture-consistent root cause is the single **persistent `TS_AUTHKEY` expiring/being revoked** (likely an *ephemeral*-type key used for *persistent* sidecars — ephemeral keys deauthorize a node once it goes offline, which matches "worked then silently died"). When that happens the sidecar never reaches `Running`, the deploy dies on an opaque `ts_status` `until` timeout, and consumers later fail with `ENETUNREACH`. This plan does **not** rotate-and-walk-away; it makes the failure **loud and self-describing at deploy time** and documents the correct key type so a key cycle can't silently break CI again.

**Out of scope / do NOT touch:** `fallen-leaf/obsidian-mcp` (its side is correct), `gaming`'s Tailscale/SSH (healthy), OpenBao (unrelated, already resolved). This plan is solely the sidecar auth/route readiness path in *this* repo.

## File Structure

- `tests/check_docker_tasks.py` — **modify.** Add constants `TAILSCALE_SIDECAR_TASKS`, `AUTHKEY_FAILFAST_MARKERS`; add `check_g_tailscale_authkey_failfast(errors)`; wire into `main()`; extend the module docstring `Checks:` list (A–F → A–G). One added responsibility: static lock-in that the sidecar role keeps the auth-aware fail-fast + route assertion.
- `playbooks/roles/tailscale_sidecar/tasks/main.yml` — **modify.** Make the existing wait task non-hard-failing, then add three tasks: parse final status, fail-fast on the auth-needed signature with an actionable message, and assert Running + a usable route. Self-contained; the role keeps its single responsibility (bring up + verify the sidecar).
- `docs/runbooks/tailscale-authkey-rotation.md` — **create.** The operator runbook: correct key type (reusable, non-ephemeral), expiry policy, exact GitHub + Gitea secret-update steps, placeholder discipline (no committed key). Referenced from the role's error messages.
- No other files. No new test fixtures (Check G reads the real role file, exactly like Check F reads the real Dockerfile).

---

### Task 1: Add the failing regression Check G (TDD lock-in)

**Files:**
- Modify: `tests/check_docker_tasks.py` (docstring `Checks:` list; constants after `DIG_PACKAGES`; new function before `def main()`; one call inside `main()` after the Check F call).

- [ ] **Step 1: Extend the module docstring Checks list**

In `tests/check_docker_tasks.py`, the docstring `Checks:` block currently ends with the `F)` entry. Add a `G)` entry immediately after the `F)` lines (leave A–F unchanged):

```
  G) tailscale_sidecar role must fail fast with an auth-aware message on an
     expired/revoked TS_AUTHKEY and assert a usable tailnet route, not just
     BackendState==Running (regression lock-in — see Gitea issue #25)
```

- [ ] **Step 2: Add the constants**

In `tests/check_docker_tasks.py`, immediately after the existing `DIG_PACKAGES = ("dnsutils", "bind9-dnsutils")` line, add:

```python
TAILSCALE_SIDECAR_TASKS = f"{ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
# Markers that must all be present in the sidecar role for the Gitea #25
# fail-fast fix to be considered in place:
#  - "NeedsLogin"  → the auth-expired/revoked BackendState is explicitly handled
#  - "Self.Online" → readiness asserts a usable route, not just Running
#  - the runbook path → the actionable error points operators at rotation
AUTHKEY_FAILFAST_MARKERS = (
    "NeedsLogin",
    "Self.Online",
    "docs/runbooks/tailscale-authkey-rotation.md",
)
```

- [ ] **Step 3: Add the check function (immediately before `def main():`)**

```python
def check_g_tailscale_authkey_failfast(errors):
    """Check G: the tailscale_sidecar role must fail fast on an
    expired/revoked TS_AUTHKEY with an actionable message AND assert a
    usable tailnet route (not just BackendState==Running).

    Without this, an expired persistent TS_AUTHKEY surfaces as an opaque
    60s Ansible `until` timeout, and a "registered but not routing"
    sidecar ships silently — downstream consumer deploys then fail with
    ENETUNREACH plays later. Lock the fix in so a refactor can't regress
    it (see Gitea issue #25).
    """
    try:
        with open(TAILSCALE_SIDECAR_TASKS) as fh:
            text = fh.read()
    except FileNotFoundError:
        errors.append(f"{TAILSCALE_SIDECAR_TASKS}: File not found")
        return

    missing = [m for m in AUTHKEY_FAILFAST_MARKERS if m not in text]
    if missing:
        errors.append(
            f"{TAILSCALE_SIDECAR_TASKS}: missing TS_AUTHKEY fail-fast / route "
            f"assertion marker(s) {missing}; the sidecar must detect an "
            f"expired/revoked key (NeedsLogin) with an actionable rotation "
            f"message and assert a usable route (Self.Online), not just "
            f"BackendState==Running. See Gitea issue #25 and "
            f"docs/runbooks/tailscale-authkey-rotation.md."
        )
```

- [ ] **Step 4: Wire it into `main()`**

In `tests/check_docker_tasks.py`, find:

```python
    # Run check F: runner image must ship a dig-providing package (#96)
    check_f_dockerfile_dns_tools(errors)
```

Add directly after it:

```python
    # Run check G: tailscale_sidecar must fail fast on a dead TS_AUTHKEY (#25)
    check_g_tailscale_authkey_failfast(errors)
```

- [ ] **Step 5: Run the check to verify it FAILS**

```bash
cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && python3 tests/check_docker_tasks.py; echo "exit=$?"
```

Expected: exactly one error line —
`ERROR: playbooks/roles/tailscale_sidecar/tasks/main.yml: missing TS_AUTHKEY fail-fast / route assertion marker(s) ['NeedsLogin', 'Self.Online', 'docs/runbooks/tailscale-authkey-rotation.md']; ...`
— then `FAILED: 1 error(s), 0 warning(s)` and `exit=1`. If more than 1 error, Checks A–F were disturbed; if 0 errors, the role already has the markers (inspect before continuing).

- [ ] **Step 6: Commit**

```bash
git add tests/check_docker_tasks.py
git commit -m "test: add Check G — tailscale_sidecar TS_AUTHKEY fail-fast lock-in (#25)"
```

---

### Task 2: Implement the auth-aware fail-fast + route assertion in the sidecar role

**Files:**
- Modify: `playbooks/roles/tailscale_sidecar/tasks/main.yml` (replace the final "Wait for Tailscale to connect to tailnet" task, lines 74–85, with the wait + three new tasks below).

- [ ] **Step 1: Replace the wait task with the fail-fast block**

In `playbooks/roles/tailscale_sidecar/tasks/main.yml`, replace this exact existing block (the file's final task):

```yaml
- name: Wait for Tailscale to connect to tailnet
  community.docker.docker_container_exec:
    container: "{{ tailscale_container_name }}"
    command: tailscale status --json
  register: ts_status
  until: >
    ts_status.rc is defined and ts_status.rc == 0 and
    (ts_status.stdout | from_json).BackendState == "Running"
  retries: 30
  delay: 2
  changed_when: false
  when: tailscale_enabled | bool and not ansible_check_mode
```

with:

```yaml
- name: Wait for Tailscale to reach Running state
  community.docker.docker_container_exec:
    container: "{{ tailscale_container_name }}"
    command: tailscale status --json
  register: ts_status
  until: >
    ts_status.rc is defined and ts_status.rc == 0 and
    (ts_status.stdout | from_json).BackendState == "Running"
  retries: 30
  delay: 2
  changed_when: false
  # Do NOT hard-fail on the until timeout: the assertions below turn a
  # dead/expired TS_AUTHKEY or a "registered but not routing" sidecar into
  # a named, actionable error instead of an opaque retry exhaustion.
  failed_when: false
  when: tailscale_enabled | bool and not ansible_check_mode

- name: Parse final Tailscale status
  set_fact:
    ts_state: >-
      {{ (ts_status.stdout | from_json)
         if (ts_status.stdout is defined and (ts_status.stdout | length) > 0)
         else {} }}
  when: tailscale_enabled | bool and not ansible_check_mode

- name: Fail fast with an actionable message when the auth key is expired or revoked
  fail:
    msg: >-
      Tailscale sidecar '{{ tailscale_container_name }}' did not authenticate
      (BackendState={{ ts_state.BackendState | default('unknown') }}). This is
      the classic expired/revoked TS_AUTHKEY signature. Rotate the key in the
      Tailscale admin console and update the TS_AUTHKEY CI secret on BOTH the
      GitHub repo and the Gitea mirror — see
      docs/runbooks/tailscale-authkey-rotation.md. Persistent sidecars require
      a reusable, NON-ephemeral key.
  when: >
    tailscale_enabled | bool and not ansible_check_mode and
    ts_state.BackendState | default('') in ['NeedsLogin', 'NoState', 'NeedsMachineAuth']

- name: Assert the sidecar is Running AND has a usable tailnet route
  assert:
    that:
      - ts_state.BackendState | default('') == 'Running'
      - ts_state.Self.Online | default(false) | bool
      - (ts_state.Peer | default({}) | length) > 0
    fail_msg: >-
      Tailscale sidecar '{{ tailscale_container_name }}' is
      BackendState={{ ts_state.BackendState | default('unknown') }},
      Self.Online={{ ts_state.Self.Online | default('?') }},
      peers={{ ts_state.Peer | default({}) | length }} — registered but NOT
      routing. Jobs proxying through this sidecar would fail with
      ENETUNREACH. If BackendState is not Running the TS_AUTHKEY is likely
      expired/revoked — see docs/runbooks/tailscale-authkey-rotation.md
      (Gitea issue #25).
    success_msg: >-
      Tailscale sidecar '{{ tailscale_container_name }}' is Running with a
      usable tailnet route ({{ ts_state.Peer | default({}) | length }} peers).
  when: tailscale_enabled | bool and not ansible_check_mode
```

- [ ] **Step 2: Run Check G to verify it now PASSES**

```bash
cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && python3 tests/check_docker_tasks.py; echo "exit=$?"
```

Expected: `PASSED: 0 errors, 0 warning(s)` and `exit=0` (the role now contains `NeedsLogin`, `Self.Online`, and the runbook path — TDD loop closes).

- [ ] **Step 3: Run the full regression suite**

```bash
cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && ansible-playbook tests/test-regression.yml
```

Expected: every `CHECK ...` task `ok`, `PLAY RECAP` `failed=0`. (CHECK 1 runs the now-passing `check_docker_tasks.py`; CHECK 6 still asserts the sidecar's `TS_SOCKS5_SERVER`/`TS_OUTBOUND_HTTP_PROXY_LISTEN` wiring, which this change does not touch.) If `ansible-playbook` is unavailable in this environment, do not treat that as a task failure: run `python3 tests/check_docker_tasks.py` and note that the full suite will run in CI; do not install ansible.

- [ ] **Step 4: YAML-lint the changed role file**

```bash
cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && yq . playbooks/roles/tailscale_sidecar/tasks/main.yml >/dev/null && echo "YAML OK"
```

Expected: `YAML OK` (valid YAML; `yq` is available in this environment).

- [ ] **Step 5: Commit**

```bash
git add playbooks/roles/tailscale_sidecar/tasks/main.yml
git commit -m "fix(tailscale): fail fast on expired/revoked TS_AUTHKEY + assert route (#25)"
```

---

### Task 3: Auth-key rotation runbook + correct key-type documentation

**Files:**
- Create: `docs/runbooks/tailscale-authkey-rotation.md`

- [ ] **Step 1: Create the runbook**

Create `docs/runbooks/tailscale-authkey-rotation.md` with exactly this content:

```markdown
# Runbook: Rotate the Tailscale sidecar auth key (`TS_AUTHKEY`)

## When to run this

A deploy fails with one of these (added for Gitea #25):

- "did not authenticate (BackendState=NeedsLogin/NoState/NeedsMachineAuth) …
  classic expired/revoked TS_AUTHKEY signature"
- "registered but NOT routing … TS_AUTHKEY is likely expired/revoked"

Or: consumer deploys (e.g. obsidian-mcp) fail with `ssh: … Network is
unreachable` to a tailnet host that is independently verified healthy.

## Why this happens

`jaxzin-infra-bootstrap` runs **persistent** Tailscale sidecars
(`tailscale-gitea`, `tailscale-runner`; `restart_policy: always`). They
authenticate with a single key from the `TS_AUTHKEY` CI secret
(`playbooks/vars/main.yml` → `tailscale_sidecar` role env).

**Persistent nodes must use a reusable, NON-ephemeral auth key.** An
ephemeral key deauthorizes and removes its node as soon as the node goes
offline (a restart, a NAS reboot, a brief outage). The node then cannot
re-authenticate on next start → "worked for days, then silently died".
Ephemeral keys also expire (often ≤ 90 days). Either failure mode presents
identically: the sidecar never reaches `Running`, the proxy can't route,
and consumer SSH/HTTatic-over-tailnet fails downstream.

## Correct key type (set this when minting)

In the Tailscale admin console → **Settings → Keys → Generate auth key**:

- **Reusable:** yes (multiple sidecars + redeploys reuse it).
- **Ephemeral:** **NO.** These are long-lived persistent nodes.
- **Expiration:** the longest your policy allows; record the expiry date in
  the team calendar / tracker so rotation is scheduled, not reactive.
- **Tags:** apply the tag your tailnet ACL grants the sidecars' required
  routes (so "registered" also means "authorized to route"). Confirm the
  ACL grants that tag a path to the consumer targets (e.g. the `gaming`
  host class). A tag with no ACL route reproduces "registered ≠ routing".

Never commit the key. It lives only in the CI secret store.

## Rotation steps (operator)

1. Mint a new key with the settings above. Copy it once.
2. Update the secret in **both** places (this repo is the bootstrap layer
   and is the only repo permitted to read CI secrets directly — both
   mirrors must match):
   - GitHub: `gh secret set TS_AUTHKEY --repo jaxzin/jaxzin-infra-bootstrap`
     (paste the key at the prompt).
   - Gitea mirror: set the `TS_AUTHKEY` Actions secret on the mirror repo
     via the Gitea UI (Settings → Actions → Secrets) or API.
3. Trigger a deploy (`Bootstrap` workflow on GitHub, or the Gitea
   `Deploy Gitea` workflow). The Task-2 fail-fast assertions will now pass
   instead of erroring; if they still error, the new key's type/tags are
   wrong — re-check "Correct key type".
4. Revoke the old key in the admin console once the deploy is green.

## Verify end to end

1. Deploy is green; sidecar bring-up logs
   `Tailscale sidecar '…' is Running with a usable tailnet route (N peers)`.
2. Re-trigger the affected consumer deploy (e.g. obsidian-mcp). Its
   Ansible `PLAY RECAP` for the tailnet-targeted host shows
   `unreachable=0`.

## Lifecycle (so this can't silently recur)

- The Task-2 assertions convert a dead key into an immediate, named deploy
  failure — it can no longer fail silently four plays downstream.
- Record the key's expiration and rotate ahead of it.
- If the tailnet policy supports it, prefer an OAuth client / tagged key
  with a managed lifecycle over a hand-minted expiring key.
```

(Placeholders only — never write the literal tailnet, domain, or host names in this file.)

- [ ] **Step 2: Verify the runbook path matches the role's error messages**

```bash
cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && \
  grep -q "docs/runbooks/tailscale-authkey-rotation.md" playbooks/roles/tailscale_sidecar/tasks/main.yml && \
  test -f docs/runbooks/tailscale-authkey-rotation.md && echo "runbook wired OK"
```

Expected: `runbook wired OK` (the role's actionable messages point at a file that now exists — no dangling reference).

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/tailscale-authkey-rotation.md
git commit -m "docs: add Tailscale auth-key rotation runbook (#25)"
```

---

### Task 4: PR, operator key rotation, and end-to-end rollout verification

**Files:** none modified. Operational: open PR, merge, operator rotates the key, redeploy, verify the fix + #25's end-to-end check. None of `tests/check_docker_tasks.py`, the role, or the runbook is under `.github/workflows/`, so a normal push works; SSH push is also fine.

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u origin HEAD
gh pr create --repo jaxzin/jaxzin-infra-bootstrap --base main \
  --title "fix(tailscale): fail fast on expired/revoked TS_AUTHKEY + route assert (refs #25)" \
  --body "$(cat <<'EOF'
## Summary
- Gitea #25 re-scoped: this repo has no per-job ephemeral Tailscale nodes;
  jobs use the persistent userspace tailscale-runner sidecar. The real
  failure mode is the persistent TS_AUTHKEY expiring/being revoked, which
  surfaced as an opaque 60s timeout and ENETUNREACH downstream.
- tailscale_sidecar role now fails fast with an auth-aware, actionable
  message on NeedsLogin/NoState/NeedsMachineAuth, and asserts a usable
  route (Running + Self.Online + peers), not just BackendState==Running.
- Check G locks the fix in (tests-as-architecture, same idiom as Check F).
- Adds docs/runbooks/tailscale-authkey-rotation.md (correct key type =
  reusable, NON-ephemeral; rotation + lifecycle steps).

Refs #25. Does not close it — closing requires the operator key rotation
(see runbook) plus the end-to-end verification below.

## Verification done locally
- check_docker_tasks.py: FAILS before the role change, PASSES after (TDD).
- tests/test-regression.yml green.

## Post-merge operator action required
The new assertions will (correctly) FAIL the deploy until a valid
reusable non-ephemeral key is set. That is the desired loud failure.
Operator: rotate per the runbook, then redeploy.
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 2: Confirm PR CI is green**

```bash
gh pr checks --repo jaxzin/jaxzin-infra-bootstrap "$(gh pr view --json number --jq .number)"
```

Expected: `Run Regression Tests` pass (Check G green via CHECK 1), `Gitleaks Scan` pass.

- [ ] **Step 3: CHECKPOINT — hand back to the operator (do not merge autonomously)**

This task has a consequential, human-only precondition and a consequential effect:

- **Precondition (human, not codeable):** the actual Tailscale auth key must be rotated in the admin console and set in the GitHub **and** Gitea `TS_AUTHKEY` secrets per `docs/runbooks/tailscale-authkey-rotation.md`. Minting a key is inherently an operator/console action; the plan cannot and must not automate it.
- **Effect:** merging triggers `build`/`deploy` paths and a real redeploy to live infrastructure.

Report status to the human partner with: PR URL, CI result, and the explicit ask — "Rotate `TS_AUTHKEY` per the runbook (reusable, non-ephemeral), then authorize merge + redeploy." **Stop here until the human confirms the key is rotated and authorizes the merge.** Do not merge or trigger a deploy before that confirmation.

- [ ] **Step 4: Merge (only after human authorization in Step 3)**

```bash
PR=$(gh pr view --json number --jq .number)
gh pr merge "$PR" --repo jaxzin/jaxzin-infra-bootstrap --squash --delete-branch
```

Expected: PR `MERGED`. (Issue #25 is referenced, not auto-closed — it closes only after Step 6 verification passes.)

- [ ] **Step 5: Redeploy and confirm the fail-fast assertions pass with a valid key**

Trigger the `Bootstrap` workflow (GitHub) — or the Gitea `Deploy Gitea` workflow — and watch the `tailscale_sidecar` tasks:

```bash
gh workflow run bootstrap.yml --repo jaxzin/jaxzin-infra-bootstrap --ref main
# then poll the run to terminal:
gh run list --repo jaxzin/jaxzin-infra-bootstrap --workflow=bootstrap.yml --limit 1 --json databaseId
```

Expected (in the run log): `Assert the sidecar is Running AND has a usable tailnet route` reports the `success_msg` (`Running with a usable tailnet route (N peers)`) for both `tailscale-gitea` and `tailscale-runner`; the run conclusion is `success`. If instead the new `fail`/`assert` fires, the rotated key's type/tags are still wrong — return to the runbook's "Correct key type" section (this is the fix working as intended: loud, named failure).

- [ ] **Step 6: End-to-end verification (Gitea #25 acceptance)**

Re-trigger the affected consumer deploy and confirm the original symptom is gone:

```bash
# obsidian-mcp deploy is on the Gitea side; dispatch its "Deploy obsidian-mcp"
# workflow (or push a non-doc change). Then inspect its Ansible PLAY RECAP.
```

Expected: the consumer's Ansible `PLAY RECAP` for the tailnet-targeted host shows `unreachable=0` (the previously-failing SSH-to-tailnet-host succeeds). Once green, comment the outcome on Gitea issue #25 and close it.

---

## Self-Review

**1. Spec coverage (Gitea #25 "Fix shape" + "Verification", re-scoped):**
- "Rotate/replace the … auth key; store in the secret manager; reference at runtime; don't commit it" → Task 3 runbook (exact GitHub + Gitea secret steps, no committed key; runtime reference already exists via `vars/main.yml:19`) + Task 4 Step 3 operator checkpoint.
- "Manage key lifecycle so a key cycle can't silently break CI again" → Task 3 (reusable/non-ephemeral key-type requirement + expiry/rotation policy) + Task 2 (a dead key now fails the deploy loudly, not silently).
- "Add a fail-fast job-time assertion: after `tailscale up`, verify status shows Running with a route before proceeding" → Task 2 (auth-aware `fail` + `Running` + `Self.Online` + peers `assert`, replacing the opaque `until` timeout).
- "Idempotent IaC, no manual one-offs" → Tasks 1–3 are idempotent (read-only checks/assertions, static lock-in, a doc). The single unavoidable manual step (minting a key) is inherent to Tailscale and is captured as a runbook + an explicit checkpoint, not a hidden hand-fix.
- "Verification (end to end): retrigger consumer deploy; PLAY RECAP unreachable=0" → Task 4 Steps 5–6.
- Bonus (codebase tests-as-architecture norm, Check F precedent) → Task 1 Check G, failing-first then passing.
- **Premise correction is itself in-scope and documented** (Background section): #25's "per-job ephemeral node" mechanism does not exist here; the plan fixes the real persistent-key path. No fabricated files.
- No gaps.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle edge cases"/"similar to". Every code/edit step shows exact content; every command shows the exact invocation and expected output. Task 4's human-only key rotation is explicitly called out as a checkpoint with concrete operator steps (runbook), not a vague "configure the key".

**3. Type/identifier consistency:** `TAILSCALE_SIDECAR_TASKS`, `AUTHKEY_FAILFAST_MARKERS`, `check_g_tailscale_authkey_failfast` are defined in Task 1 and referenced consistently; the `main()` call site matches the function name; docstring list A–G matches the function set. The three markers asserted by Check G (`NeedsLogin`, `Self.Online`, `docs/runbooks/tailscale-authkey-rotation.md`) each appear verbatim in Task 2's role code and Task 3's runbook path — the lock-in and the implementation agree. `ts_state`/`ts_status` are introduced and reused consistently within the role tasks. Plan saved under the repo convention `docs/plans/` (not the skill default), matching the prior plan.
