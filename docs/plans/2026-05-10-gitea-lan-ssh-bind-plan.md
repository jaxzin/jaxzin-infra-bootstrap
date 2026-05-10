# Gitea LAN-SSH Bind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Gitea's SSH service on the NAS LAN interface (in addition to the existing tailnet path) so LAN clients — including Home Assistant addon containers that have no tailnet access — can perform git push/pull over SSH using a configurable LAN host:port.

**Architecture:** Add two new env-driven variables (`gitea_lan_host`, `gitea_lan_ssh_port`) to `playbooks/vars/main.yml`. Append a new entry to the `tailscale_host_ports` list passed to the Gitea Tailscale sidecar in `playbooks/gitea-deploy.yml`, binding `<lan-host>:<lan-port>` to the container's internal SSH port (`22`). The container shares its network namespace with the sidecar (`network_mode: container:`), so the sidecar's host-port publication is what makes the SSH listener reachable from the LAN. New values flow from CI Secrets → workflow env → playbook vars (mirrors the existing pattern; uses Secrets — not Variables — because both values are topology and must not appear in public workflow logs).

**Tech Stack:** Ansible, Docker (`community.docker.docker_container`), GitHub Actions, Gitea Actions

**Tracking:** Issue #5 deliverable #1.

**Prerequisites:**
- Issue #6 (Variables → Secrets migration) should land first to keep the Secret-only-for-topology pattern uniform across the repo. This plan adopts that pattern from the start for its new values regardless.

---

### Task 1: Add the new variables to `playbooks/vars/main.yml`

**Files:**
- Modify: `playbooks/vars/main.yml`

- [ ] **Step 1: Read the existing file to find the Gitea configuration section**

Open `playbooks/vars/main.yml` and locate the `# Gitea configuration` section (around line 44). Note where `gitea_ssh_listen_port` is defined (around line 52) — the new values belong nearby.

- [ ] **Step 2: Add the two new variables**

Add the following lines immediately after the `gitea_ssh_listen_port` definition. Keep them in the same `# Gitea configuration` section so related knobs stay grouped:

```yaml
# LAN-side SSH binding: makes Gitea SSH reachable from non-tailnet LAN clients
# (e.g., Home Assistant addon containers). Bound on the host's LAN interface
# at gitea_lan_host:gitea_lan_ssh_port → container's internal :22.
# Both values must come from CI Secrets (not Variables) because they're topology.
gitea_lan_host: "{{ lookup('ansible.builtin.env', 'GITEA_LAN_HOST') }}"
gitea_lan_ssh_port: "{{ lookup('ansible.builtin.env', 'GITEA_LAN_SSH_PORT') | default('2222', true) }}"
```

`gitea_lan_host` has no default — the deployment must specify it. `gitea_lan_ssh_port` defaults to `2222` so a missing value doesn't accidentally bind on `:22` (which would conflict with the host sshd) or silently use the empty string.

- [ ] **Step 3: Commit**

```bash
git add playbooks/vars/main.yml
git commit -m "feat(gitea): add gitea_lan_host/port vars for LAN SSH binding"
```

---

### Task 2: Validate the new variables in the deploy playbook

**Files:**
- Modify: `playbooks/gitea-deploy.yml`

- [ ] **Step 1: Locate the existing validation block**

Open `playbooks/gitea-deploy.yml` and find the `Validate required variables` task (around line 17). It uses an `assert` with a `loop` listing the required variable names.

- [ ] **Step 2: Add the new variable to the validation loop**

Add `gitea_lan_host` to the loop. Do NOT add `gitea_lan_ssh_port` — it has a default and is therefore not required. The block should look like:

```yaml
- name: Validate required variables
  assert:
    that:
      - lookup('vars', item) is defined
      - lookup('vars', item) | string != ""
    fail_msg: "The required variable '{{ item }}' is undefined or is empty."
  loop:
    - certbot_email
    - discord_webhook
    - dnsimple_endpoint
    - dnsimple_oauth_token
    - gitea_admin_username
    - gitea_admin_password
    - gitea_admin_email
    - gitea_db_password
    - tailscale_tailnet
    - lan_domain
    - gitea_lan_host
```

- [ ] **Step 3: Commit**

```bash
git add playbooks/gitea-deploy.yml
git commit -m "chore(deploy): validate gitea_lan_host before provisioning"
```

---

### Task 3: Bind the LAN port through the Gitea Tailscale sidecar

**Files:**
- Modify: `playbooks/gitea-deploy.yml`

- [ ] **Step 1: Locate the Gitea sidecar `tailscale_host_ports` list**

In `playbooks/gitea-deploy.yml`, find the `Deploy Tailscale sidecar for Gitea` task (around line 59). Inside its `vars:` block, the relevant line is:

```yaml
        tailscale_host_ports:
          - "127.0.0.1:{{ gitea_port }}:3000"
```

This currently publishes only the loopback HTTP port. To expose SSH on the LAN, append a second entry that binds `<lan-host>:<lan-port>` to the container's internal SSH port (`22`).

- [ ] **Step 2: Add the LAN SSH binding entry**

Replace the `tailscale_host_ports` block with:

```yaml
        tailscale_host_ports:
          - "127.0.0.1:{{ gitea_port }}:3000"
          - "{{ gitea_lan_host }}:{{ gitea_lan_ssh_port }}:22"
```

The internal port is `22` — the container's actual SSH listener — not `gitea_ssh_listen_port` (`2222`), which is the *Tailscale Serve* TCPForward target on the tailnet side. The two paths (tailnet via Serve, LAN via host-port) are independent and both ultimately reach the same container :22.

- [ ] **Step 3: Re-render the playbook in check mode to spot syntax issues**

```bash
ansible-playbook --syntax-check playbooks/gitea-deploy.yml
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add playbooks/gitea-deploy.yml
git commit -m "feat(gitea): expose Gitea SSH on LAN via gitea_lan_host:port"
```

---

### Task 4: Wire the new Secrets through the GitHub bootstrap workflow

**Files:**
- Modify: `.github/workflows/common-bootstrap.yml`

- [ ] **Step 1: Read the existing `env:` block**

In `.github/workflows/common-bootstrap.yml`, the `env:` block (around lines 16–33) maps GitHub Actions secrets/vars to environment variables that the playbook will see.

- [ ] **Step 2: Add the two new env mappings**

Insert these two lines somewhere in the `env:` block (alphabetical position is fine, or grouped with other `GITEA_*` entries):

```yaml
      GITEA_LAN_HOST: ${{ secrets.GITEA_LAN_HOST }}
      GITEA_LAN_SSH_PORT: ${{ secrets.GITEA_LAN_SSH_PORT }}
```

Both reference `secrets.*`, never `vars.*`. The values are topology and must not appear in workflow logs (they would, if stored as Variables, since Variables are not redacted).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/common-bootstrap.yml
git commit -m "ci(github): pass GITEA_LAN_HOST/PORT secrets to bootstrap"
```

---

### Task 5: Wire the new Secrets through the Gitea deploy workflow

**Files:**
- Modify: `.gitea/workflows/deploy.yml`

- [ ] **Step 1: Read the file**

Open `.gitea/workflows/deploy.yml`. Identify the equivalent `env:` block (or the secrets-passing pattern that mirrors the GitHub workflow).

- [ ] **Step 2: Add the two new env mappings**

Mirror the change from Task 4 — add:

```yaml
      GITEA_LAN_HOST: ${{ secrets.GITEA_LAN_HOST }}
      GITEA_LAN_SSH_PORT: ${{ secrets.GITEA_LAN_SSH_PORT }}
```

If `.gitea/workflows/deploy.yml` uses a different shape (e.g., `inputs` or a separate matrix), match the existing pattern in that file rather than copying GitHub's verbatim. The principle: the Ansible playbook needs both env vars set when it runs.

- [ ] **Step 3: Commit**

```bash
git add .gitea/workflows/deploy.yml
git commit -m "ci(gitea): pass GITEA_LAN_HOST/PORT secrets to deploy"
```

---

### Task 6: Document the new Secrets in `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the Secrets table**

In `README.md`, find the table that lists `Secret | Value/Purpose` (around lines 187–199).

- [ ] **Step 2: Add two rows for the new Secrets**

Add the following two rows to the Secrets table, alphabetically positioned (between `B2_BUCKET_NAME` and `DISCORD_WEBHOOK` placement-wise):

```markdown
| `GITEA_LAN_HOST`   | LAN-facing host/IP the Gitea SSH service binds to (e.g., the NAS LAN IP). Topology — must be a Secret, not a Variable. |
| `GITEA_LAN_SSH_PORT`    | LAN port for Gitea SSH (defaults to `2222` if unset). Pick a non-22 port to avoid collision with the host sshd. |
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document GITEA_LAN_HOST/PORT secrets"
```

---

### Task 7: Add a regression test for the `tailscale_host_ports` shape

**Files:**
- Modify: `tests/check_docker_tasks.py`
- Modify: `tests/test-regression.yml` (verify the existing "CHECK 1" still runs)

This task adds a sanity check that the `tailscale_host_ports` list passed to the Gitea sidecar contains both entries: the loopback HTTP entry AND the LAN SSH entry. The check uses synthetic values (no real IPs) — it verifies *shape*, not *value*.

- [ ] **Step 1: Read the existing validator**

Open `tests/check_docker_tasks.py` and identify how it parses task blocks. The existing `Check A` function looks at `community.docker.docker_container` tasks.

- [ ] **Step 2: Add a new check function**

Add a new check `Check D` that:

1. Parses `playbooks/gitea-deploy.yml` (not a role file — this list lives in the playbook).
2. Locates the `Deploy Tailscale sidecar for Gitea` task block.
3. Asserts that the `tailscale_host_ports` list contains BOTH:
   - An entry matching `r'^127\.0\.0\.1:.*:3000$'` (the existing HTTP loopback)
   - An entry matching `r'^\{\{\s*gitea_lan_host\s*\}\}:\{\{\s*gitea_lan_ssh_port\s*\}\}:22$'` (the new LAN SSH binding, in template form because the file is unrendered)

```python
GITEA_HOST_PORTS_REQUIRED = [
    re.compile(r'^["\']?127\.0\.0\.1:.*:3000["\']?$'),
    re.compile(r'^["\']?\{\{\s*gitea_lan_host\s*\}\}:\{\{\s*gitea_lan_ssh_port\s*\}\}:22["\']?$'),
]

def check_d_gitea_sidecar_host_ports():
    """The Gitea Tailscale sidecar must publish loopback HTTP AND LAN SSH."""
    path = "playbooks/gitea-deploy.yml"
    with open(path) as fh:
        lines = fh.readlines()

    # Find the "Deploy Tailscale sidecar for Gitea" task block
    blocks = split_into_task_blocks(lines)
    target = next(
        (b for b in blocks if any("Deploy Tailscale sidecar for Gitea" in ln for ln in b)),
        None,
    )
    if target is None:
        return [f"{path}: missing 'Deploy Tailscale sidecar for Gitea' task"]

    # Extract list items under tailscale_host_ports
    in_list = False
    items = []
    for ln in target:
        s = ln.lstrip()
        if s.startswith("tailscale_host_ports:"):
            in_list = True
            continue
        if in_list:
            if s.startswith("- "):
                items.append(s[2:].strip())
            elif s and not s.startswith("#") and not ln.startswith(("    ", "\t")):
                # de-dented out of the list
                break

    failures = []
    for required in GITEA_HOST_PORTS_REQUIRED:
        if not any(required.match(item) for item in items):
            failures.append(
                f"{path}: tailscale_host_ports for Gitea sidecar missing entry "
                f"matching {required.pattern!r}; found: {items}"
            )
    return failures
```

Then call `check_d_gitea_sidecar_host_ports()` from the script's main block alongside the existing checks, and accumulate its failures into the same exit-code logic.

- [ ] **Step 3: Run the regression suite to confirm the test passes**

```bash
ansible-playbook tests/test-regression.yml
```

Expected: all checks pass, including the new Check D.

- [ ] **Step 4: Negative-test the regression check (sanity)**

Temporarily comment out the new LAN SSH entry in `playbooks/gitea-deploy.yml` and re-run:

```bash
ansible-playbook tests/test-regression.yml
```

Expected: the regression run fails with a clear message naming the missing pattern. Then restore the entry and re-verify the run passes.

- [ ] **Step 5: Commit**

```bash
git add tests/check_docker_tasks.py
git commit -m "test: regression check for Gitea sidecar LAN SSH host_ports"
```

---

### Task 8: Manual end-to-end verification (one-time, post-deploy)

This task is **not** part of CI. It runs after a real deploy to confirm the binding works end-to-end. Document the procedure as a note in this plan; the operator runs it after the next bootstrap/deploy completes.

- [ ] **Step 1: Run a deploy that picks up the new vars**

Trigger the normal Gitea deployment workflow (Gitea push to `main` → Gitea Actions, or GitHub `bootstrap.yml` for DR). Confirm the workflow run sets the `GITEA_LAN_HOST` and `GITEA_LAN_SSH_PORT` secrets in its env, and that Ansible reports the Gitea sidecar container as `changed` (re-created with the new port binding).

- [ ] **Step 2: Verify the host port is listening on the LAN interface**

From a LAN client (NOT via tailnet — pick a device with no tailnet access, e.g., a phone on the regular Wi-Fi):

```bash
nc -vz <GITEA_LAN_HOST> <GITEA_LAN_SSH_PORT>
```

Expected: `succeeded` / connection open.

- [ ] **Step 3: Verify the SSH listener responds with Gitea's banner (not the host sshd)**

```bash
ssh -T -p <GITEA_LAN_SSH_PORT> git@<GITEA_LAN_HOST>
```

Expected, when no key is registered: `Permission denied (publickey).` — *clean publickey rejection from Gitea, not a password prompt from Synology DSM's bare-metal sshd*. If you see a password prompt, you've hit the wrong listener — port collision; re-pick `GITEA_LAN_SSH_PORT`.

Once a known SSH key is added to a Gitea user, the same command should print `Hi <user>! You've successfully authenticated, but Gitea does not provide shell access.`

- [ ] **Step 4: Verify the tailnet path still works (regression)**

```bash
ssh -T git@<gitea-tailnet-hostname>
```

Expected: same Gitea banner. The LAN bind must not have broken the existing tailnet route.

- [ ] **Step 5: Document completion**

Add a one-line note to the PR description (or close issue #5 deliverable #1's tracking comment) confirming the LAN-bound port and the date verified. Do NOT include the actual port number or LAN IP in commit messages, PR titles, or any github.com-mirrored artifact — reference only the Secret names.

---

## Out of scope for this plan

- Adding a UniFi static-DNS record so this binding is reachable by name. That's a separate plan (deliverable #2).
- Managing Gitea deploy keys via the Gitea API. Tracked separately (deliverable #3).
- Migrating existing Variables to Secrets. Tracked in issue #6.
