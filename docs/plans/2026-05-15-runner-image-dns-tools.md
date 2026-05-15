# Runner Image `dig` Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `Verify DNS resolution after apply` step in `network.yml` (and the nightly `tofu-network-drift` job) pass by ensuring the self-hosted runner image ships `dig`, and lock that dependency in with a static regression check so it can't silently regress.

**Architecture:** Add a `dig`-providing apt package to the single existing `apt-get install` layer in `Dockerfile`. Before touching the Dockerfile, add a failing static assertion to `tests/check_docker_tasks.py` (the repo's existing stdlib source-invariant validator, auto-run by `tests/test-regression.yml` CHECK 1) that fails when no `dig` package is present and passes once it is — the same tests-as-architecture lock-in pattern used for Checks A–E. Then roll the rebuilt image out via the existing `build-runner.yml` (triggers on `Dockerfile` changes to `main`) and verify end-to-end by re-running `network.yml`.

**Tech Stack:** Docker (`ghcr.io/catthehacker/ubuntu:act-24.04` base, `apt`), Python 3 stdlib (`tests/check_docker_tasks.py`), Ansible (`tests/test-regression.yml`), GitHub Actions (`build-runner.yml`, `network.yml`), `gh` CLI.

---

## Background (issue #96)

`network.yml`'s `Verify DNS resolution after apply` step runs `dig +short "$GITEA_LAN_FQDN" @"$LAN_DNS"`. The base image does not ship `dig`, so the step dies with `dig: not found` / exit 127. This was masked until now because the workflow never reached that step (first the `secrets`-in-`container.options` schema error, then the UniFi TLS error). `tofu apply` itself succeeds — the failure is the post-apply self-check only. Issue #96 prescribes the proper fix: add a `dig`-providing package to the existing apt layer in `Dockerfile`, then rebuild/republish the runner image.

`dnsutils` is the conventional package name and remains valid on the Ubuntu 24.04 base (it is a transitional package pulling `bind9-dnsutils`). The regression check accepts either name so a future maintainer can switch to the canonical `bind9-dnsutils` without breaking the lock-in.

## File Structure

- `tests/check_docker_tasks.py` — **modify.** Add module-level constants `DOCKERFILE_PATH`, `DIG_PACKAGES`; add `check_f_dockerfile_dns_tools(errors)`; call it from `main()`; extend the module docstring `Checks:` list (A–E → A–F). One clear responsibility added: static assertion that the runner image installs a `dig` provider.
- `Dockerfile` — **modify.** Add `dnsutils` to the existing single `apt-get install -y ...` list on line 10. No new `RUN` layer (keeps the existing `rm -rf /var/lib/apt/lists/*` cleanup effective and image size flat).
- No new files. No test fixture files (the check reads the real `Dockerfile`, consistent with how Check D/E read real source files).

## Rollout / verification surfaces (no code change, referenced by Task 3)

- `.github/workflows/build-runner.yml` — already triggers `on: push: branches: [main] paths: ['Dockerfile']` and on `workflow_dispatch`. Rebuilds and pushes `ghcr.io/jaxzin/jaxzin-infra-runner:latest`. No edit needed.
- `.github/workflows/network.yml` — has no `workflow_dispatch`; re-verification is done via `gh run rerun` of its most recent `main` run (a rerun re-pulls the `container:` image at job start, so it picks up the rebuilt `:latest`).

---

### Task 1: Add the failing regression check (Check F)

**Files:**
- Modify: `tests/check_docker_tasks.py:1-20` (docstring + constants), add function before `def main()` (around `tests/check_docker_tasks.py:257`), and add a call inside `main()` (around `tests/check_docker_tasks.py:279`).

- [ ] **Step 1: Extend the module docstring Checks list**

In `tests/check_docker_tasks.py`, change the docstring block (lines 4–12) from:

```python
Checks:
  A) network_mode: container:* tasks must not have dns_opts/dns/networks/ports
  B) tailscale_sidecar container task must include TS_ACCEPT_DNS env var
  C) standalone container tasks should have networks defined (warning)
  D) Gitea Tailscale sidecar tailscale_host_ports must include loopback HTTP
     AND LAN SSH bindings
  E) gitea-runner task must NOT use network_mode: container:* (regression
     lock-in — see docs/architecture/tailscale-sidecar-modes.md)
```

to:

```python
Checks:
  A) network_mode: container:* tasks must not have dns_opts/dns/networks/ports
  B) tailscale_sidecar container task must include TS_ACCEPT_DNS env var
  C) standalone container tasks should have networks defined (warning)
  D) Gitea Tailscale sidecar tailscale_host_ports must include loopback HTTP
     AND LAN SSH bindings
  E) gitea-runner task must NOT use network_mode: container:* (regression
     lock-in — see docs/architecture/tailscale-sidecar-modes.md)
  F) runner image Dockerfile must install a dig-providing apt package
     (network.yml's post-apply DNS verify step needs `dig` — see issue #96)
```

- [ ] **Step 2: Add the constants**

After line 20 (`FORBIDDEN_WITH_CONTAINER_MODE = [...]`) in `tests/check_docker_tasks.py`, add:

```python
DOCKERFILE_PATH = "Dockerfile"
# Either name provides `dig`. `dnsutils` is conventional and still valid on
# Ubuntu 24.04 (transitional package -> bind9-dnsutils); accept both so the
# lock-in does not break if a maintainer switches to the canonical name.
DIG_PACKAGES = ("dnsutils", "bind9-dnsutils")
```

- [ ] **Step 3: Add the check function**

Immediately before `def main():` in `tests/check_docker_tasks.py`, add:

```python
def check_f_dockerfile_dns_tools(errors):
    """Check F: the runner image must install a `dig`-providing apt package.

    network.yml's "Verify DNS resolution after apply" step shells out to
    `dig`. The base image does not ship it, so that step fails with exit
    127 once the workflow reaches it. Lock the dependency in here so a
    future Dockerfile edit cannot silently drop it (see issue #96).
    """
    try:
        with open(DOCKERFILE_PATH) as fh:
            text = fh.read()
    except FileNotFoundError:
        errors.append(f"{DOCKERFILE_PATH}: file not found")
        return

    if "apt-get install" not in text:
        errors.append(
            f"{DOCKERFILE_PATH}: expected an `apt-get install` layer; none found"
        )
        return

    if not any(re.search(rf"\b{re.escape(pkg)}\b", text) for pkg in DIG_PACKAGES):
        errors.append(
            f"{DOCKERFILE_PATH}: no dig-providing apt package installed "
            f"(expected one of {DIG_PACKAGES}); the network.yml "
            f"'Verify DNS resolution after apply' step needs `dig`. "
            f"See issue #96."
        )
```

- [ ] **Step 4: Wire it into `main()`**

In `tests/check_docker_tasks.py`, find this block in `main()` (around line 278):

```python
    # Run check E: gitea-runner must not regress to network_mode: container:*
    check_e_runner_no_container_network_mode(errors)
```

Add directly after it:

```python
    # Run check F: runner image must ship a dig-providing package (#96)
    check_f_dockerfile_dns_tools(errors)
```

- [ ] **Step 5: Run the check to verify it FAILS**

Run from the repo root:

```bash
python3 tests/check_docker_tasks.py; echo "exit=$?"
```

Expected: a line
`ERROR: Dockerfile: no dig-providing apt package installed (expected one of ('dnsutils', 'bind9-dnsutils')); ... See issue #96.`
then `FAILED: 1 error(s), 0 warning(s)` and `exit=1`.

(If it unexpectedly PASSES, the Dockerfile already has a dig package — inspect `Dockerfile` line 10 and stop; the rest of this plan is moot.)

- [ ] **Step 6: Commit the failing check**

```bash
git add tests/check_docker_tasks.py
git commit -m "test: add Check F — runner image must install a dig provider (#96)"
```

---

### Task 2: Make the check pass — add `dnsutils` to the Dockerfile

**Files:**
- Modify: `Dockerfile:10`

- [ ] **Step 1: Add `dnsutils` to the existing apt layer**

In `Dockerfile`, change line 10 from:

```dockerfile
    apt-get install -y python3 python3-pip sshpass git iptables && \
```

to:

```dockerfile
    apt-get install -y python3 python3-pip sshpass git iptables dnsutils && \
```

Do **not** add a new `RUN` instruction and do **not** move the `rm -rf /var/lib/apt/lists/*` cleanup — keeping `dnsutils` in the same layer preserves the existing cache cleanup and keeps image size flat.

- [ ] **Step 2: Run the regression check to verify it PASSES**

```bash
python3 tests/check_docker_tasks.py; echo "exit=$?"
```

Expected: `PASSED: 0 errors, 0 warning(s)` and `exit=0`.

- [ ] **Step 3: Run the full regression suite to confirm nothing else broke**

```bash
ansible-playbook tests/test-regression.yml
```

Expected: every `CHECK ...` task `ok`, final `PLAY RECAP` shows `failed=0` (in particular `CHECK 1: Run Docker task structural validator` is `ok`, since it shells out to the now-passing `check_docker_tasks.py`).

- [ ] **Step 4 (optional, requires local Docker): prove `dig` resolves in the built image**

Only if a local Docker daemon is available. This is the true end-to-end proof; skip with a note if Docker is unavailable in the working environment.

```bash
docker build -t jaxzin-infra-runner-test . && \
  docker run --rm jaxzin-infra-runner-test dig -v
```

Expected: build succeeds; `dig -v` prints a line like `DiG 9.x.x` to stderr/stdout (exit 0). Then clean up:

```bash
docker rmi jaxzin-infra-runner-test
```

- [ ] **Step 5: Commit the fix**

```bash
git add Dockerfile
git commit -m "fix(ci): install dnsutils in runner image so network.yml dig step works (#96)"
```

---

### Task 3: PR, image rebuild rollout, and end-to-end verification

**Files:** none modified. Operational steps: open PR, merge, observe the image rebuild, re-verify `network.yml`.

Neither `Dockerfile` nor `tests/check_docker_tasks.py` is under `.github/workflows/`, so the standard `gh`-credential HTTPS push works (the `workflow`-scope restriction does not apply here). SSH push also works if preferred.

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u origin HEAD
gh pr create --repo jaxzin/jaxzin-infra-bootstrap --base main \
  --title "fix(ci): install dnsutils in runner image + lock it in (fixes #96)" \
  --body "$(cat <<'EOF'
## Summary
- Add `dnsutils` to the runner image's existing apt layer so `dig` exists.
- Add Check F to tests/check_docker_tasks.py so the dependency cannot
  silently regress (same tests-as-architecture pattern as Checks A-E).

Fixes #96.

## Verification done locally
- `python3 tests/check_docker_tasks.py` FAILS before the Dockerfile edit,
  PASSES after (TDD).
- `ansible-playbook tests/test-regression.yml` green.

## Rollout note
Merging triggers `build-runner.yml` (Dockerfile path on main) to rebuild
and push `:latest`. The next `network.yml` run re-pulls the image at job
start and the post-apply `dig` verify step should pass.
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 2: Confirm CI on the PR is green**

```bash
gh pr checks --repo jaxzin/jaxzin-infra-bootstrap "$(gh pr view --json number --jq .number)"
```

Expected: `Run Regression Tests` = pass (it runs the now-passing Check F), `Gitleaks Scan` = pass.

- [ ] **Step 3: Merge the PR**

```bash
PR=$(gh pr view --json number --jq .number)
gh pr merge "$PR" --repo jaxzin/jaxzin-infra-bootstrap --squash --delete-branch
```

Expected: PR state `MERGED`; issue #96 auto-closed (the PR body has `Fixes #96`).

- [ ] **Step 4: Confirm the runner image rebuild ran and succeeded**

The merge pushes `Dockerfile` to `main`, triggering `build-runner.yml`.

```bash
sleep 8
gh run list --repo jaxzin/jaxzin-infra-bootstrap \
  --workflow=build-runner.yml --branch main --limit 1 \
  --json databaseId,status,conclusion,event
```

Expected: one run, `event=push`, eventually `status=completed conclusion=success`. Poll until terminal (re-run the command, or watch it) before continuing — the rebuilt `:latest` must exist in the registry before Step 5.

- [ ] **Step 5: Re-verify `network.yml` end-to-end**

`network.yml` has no `workflow_dispatch`; re-run its most recent `main` run (a rerun re-pulls the `container:` image at job start, so it uses the freshly rebuilt `:latest`). `tofu apply` is idempotent — if the DNS record already matches state this is a no-op apply.

```bash
RID=$(gh run list --repo jaxzin/jaxzin-infra-bootstrap \
  --workflow=network.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')
gh run rerun "$RID" --repo jaxzin/jaxzin-infra-bootstrap
```

Then wait for it to finish and inspect the previously-failing step:

```bash
gh run view "$RID" --repo jaxzin/jaxzin-infra-bootstrap \
  --json jobs --jq '.jobs[].steps[] | select(.name=="Verify DNS resolution after apply") | "\(.name): \(.status)/\(.conclusion)"'
```

Expected: `Verify DNS resolution after apply: completed/success`, and the run's overall conclusion `success`.

- [ ] **Step 6: Contingency — stale cached image on the self-hosted runner host**

GitHub Actions normally `docker pull`s the `container:` image at job start, so the rebuilt `:latest` is picked up automatically. If Step 5's verify step *still* reports `dig: not found`, the self-hosted runner host is using a stale cached `:latest`. Resolve by forcing a fresh pull on that host, then re-run:

```bash
# On the self-hosted runner host (generic — do not hardcode host details):
docker pull ghcr.io/jaxzin/jaxzin-infra-runner:latest
# (or remove the stale image so the next job re-pulls:)
# docker rmi ghcr.io/jaxzin/jaxzin-infra-runner:latest
```

Then repeat Step 5's `gh run rerun` + verify. Expected after the fresh pull: `Verify DNS resolution after apply: completed/success`.

- [ ] **Step 7: Confirm the nightly drift job is no longer red for this reason**

Passive confirmation (no action): the next scheduled `health-check.yml` `tofu-network-drift` job (cron `0 0 * * *`) should also clear the `dig`-not-found failure. Check after the next nightly run:

```bash
gh run list --repo jaxzin/jaxzin-infra-bootstrap \
  --workflow=health-check.yml --limit 1 \
  --json conclusion,createdAt
```

Expected: the `tofu-network-drift` job no longer fails solely on `dig: not found` (it may still report drift/no-drift per its normal semantics — that is out of scope for #96).

---

## Self-Review

**1. Spec coverage (issue #96 acceptance criteria):**
- "Dockerfile installs a `dig`-providing package in the existing apt layer" → Task 2 Step 1 (same `RUN`, line 10).
- "Runner image rebuilt + published (`build-runner.yml`)" → Task 3 Step 4 (triggered by the merged Dockerfile change; verified).
- "A subsequent `network.yml` run completes green through `Verify DNS resolution after apply`" → Task 3 Step 5 (+ Step 6 contingency).
- "Nightly `tofu-network-drift` no longer red solely due to missing `dig`" → Task 3 Step 7.
- Bonus lock-in (codebase tests-as-architecture norm; mirrors PR #93 precedent) → Task 1 (Check F), failing-first then passing.
- No gaps.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle edge cases"/"similar to". Every code step shows the exact code; every command step shows the exact command and expected output. The image-cache contingency (Task 3 Step 6) gives concrete commands, not "handle errors appropriately".

**3. Type/identifier consistency:** `DOCKERFILE_PATH`, `DIG_PACKAGES`, and `check_f_dockerfile_dns_tools` are defined in Task 1 and referenced consistently; the `main()` call site matches the function name; the docstring list (A–F) matches the function set. `dnsutils` is used consistently in the Dockerfile edit and accepted by `DIG_PACKAGES`. Plan location follows the repo convention (`docs/plans/`), not the skill default.
