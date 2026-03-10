# Regression Test Suite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add fast regression tests that catch the Docker networking, MagicDNS, hardcoded path, and template rendering bugs discovered during the Tailscale sidecar integration.

**Architecture:** Two-layer approach — a stdlib-only Python script for YAML structural validation (no PyYAML dependency), plus an Ansible playbook for template rendering checks and path auditing. Both run on localhost with no Docker, NAS, or secrets required.

**Tech Stack:** Python 3 (stdlib only), Ansible, GNU grep, GitHub Actions

---

### Task 1: Create Python structural validator

**Files:**
- Create: `tests/check_docker_tasks.py`

**Step 1: Write the Python script**

This script uses only Python stdlib (no PyYAML). It reads Ansible task files line-by-line,
splits them into task blocks by detecting `- name:` boundaries, then checks each
`community.docker.docker_container` task block for:

- **Check A (Gaps 1 & 4)**: Tasks with `network_mode:` containing `container:` must NOT
  have `dns_opts`, `dns`, `dns_search`, `networks`, or `ports` keys.
- **Check B (Gap 2)**: The `tailscale_sidecar` role's docker_container task must include
  `TS_ACCEPT_DNS` in its env block.
- **Check C (Gap 4 standalone)**: docker_container tasks WITHOUT `network_mode: container:`
  should have `networks` defined (warning only, non-fatal).

```python
#!/usr/bin/env python3
"""Validate Ansible docker_container tasks for network parameter correctness.

Checks:
  A) network_mode: container:* tasks must not have dns_opts/dns/networks/ports
  B) tailscale_sidecar container task must include TS_ACCEPT_DNS env var
  C) standalone container tasks should have networks defined (warning)

Uses only Python stdlib — no PyYAML required.
"""
import glob
import re
import sys

ROLES_DIR = "playbooks/roles"
FORBIDDEN_WITH_CONTAINER_MODE = ["dns_opts", "dns:", "dns_search", "networks", "ports"]

def split_into_task_blocks(lines):
    """Split file lines into task blocks. Each block starts with '- name:'."""
    blocks = []
    current = []
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("- name:") and current:
            blocks.append(current)
            current = []
        current.append(line)
    if current:
        blocks.append(current)
    return blocks

def is_docker_container_task(block):
    """Check if this task block uses community.docker.docker_container."""
    text = "\n".join(block)
    return "community.docker.docker_container" in text or "docker_container:" in text

def has_container_network_mode(block):
    """Check if task block has network_mode: container:*"""
    for line in block:
        if re.search(r'network_mode:\s*["\']?container:', line):
            return True
    return False

def has_key_in_block(block, key):
    """Check if a YAML key appears in the docker_container parameter block."""
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith(f"{key}:") or stripped.startswith(f"{key} :"):
            return True
        # Also check for key as bare list parent (dns_opts:\n  - ...)
        if key == "dns_opts" and stripped.startswith("dns_opts"):
            return True
    return False

def has_env_var(block, var_name):
    """Check if a specific env var key appears in the task's env: block."""
    text = "\n".join(block)
    return var_name in text

def check_file(filepath, errors, warnings):
    """Run all checks on a single task file."""
    with open(filepath) as f:
        lines = f.readlines()

    blocks = split_into_task_blocks(lines)

    for block in blocks:
        if not is_docker_container_task(block):
            continue

        task_name = ""
        for line in block:
            m = re.search(r'-\s*name:\s*(.+)', line)
            if m:
                task_name = m.group(1).strip()
                break

        # Check A: container network mode must not have forbidden params
        if has_container_network_mode(block):
            for key in FORBIDDEN_WITH_CONTAINER_MODE:
                clean_key = key.rstrip(":")
                if has_key_in_block(block, clean_key):
                    errors.append(
                        f"{filepath}: Task '{task_name}' uses network_mode: container: "
                        f"but also has '{clean_key}' (incompatible)"
                    )

        # Check C: standalone tasks should have networks
        if not has_container_network_mode(block):
            if not has_key_in_block(block, "networks"):
                # Only warn if it's not using network_mode at all
                has_any_network_mode = any("network_mode:" in line for line in block)
                if not has_any_network_mode:
                    warnings.append(
                        f"{filepath}: Task '{task_name}' has no 'networks' or "
                        f"'network_mode' — container may use default bridge network"
                    )

def check_tailscale_sidecar(errors):
    """Check B: tailscale_sidecar must have TS_ACCEPT_DNS in env."""
    filepath = f"{ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
    try:
        with open(filepath) as f:
            lines = f.readlines()
    except FileNotFoundError:
        errors.append(f"{filepath}: File not found")
        return

    blocks = split_into_task_blocks(lines)
    found_sidecar_task = False

    for block in blocks:
        if not is_docker_container_task(block):
            continue
        found_sidecar_task = True
        if not has_env_var(block, "TS_ACCEPT_DNS"):
            errors.append(
                f"{filepath}: Tailscale sidecar docker_container task is missing "
                f"TS_ACCEPT_DNS in env (MagicDNS will be disabled)"
            )

    if not found_sidecar_task:
        errors.append(f"{filepath}: No docker_container task found in tailscale_sidecar role")

def main():
    errors = []
    warnings = []

    # Find all role task files
    task_files = glob.glob(f"{ROLES_DIR}/*/tasks/main.yml")
    if not task_files:
        print(f"ERROR: No task files found in {ROLES_DIR}/*/tasks/main.yml")
        sys.exit(1)

    # Run checks A & C on all roles
    for filepath in task_files:
        check_file(filepath, errors, warnings)

    # Run check B on tailscale_sidecar specifically
    check_tailscale_sidecar(errors)

    # Report results
    for w in warnings:
        print(f"WARN:  {w}")
    for e in errors:
        print(f"ERROR: {e}")

    if errors:
        print(f"\nFAILED: {len(errors)} error(s), {len(warnings)} warning(s)")
        sys.exit(1)
    else:
        print(f"\nPASSED: 0 errors, {len(warnings)} warning(s)")
        sys.exit(0)

if __name__ == "__main__":
    main()
```

**Step 2: Run the script to verify it passes against current code**

Run: `cd /Users/jaxzin/Projects/jaxzin-infra-bootstrap && python3 tests/check_docker_tasks.py`
Expected: PASSED (since we already fixed the dns_opts bug)

**Step 3: Temporarily reintroduce the bug to verify the test catches it**

Add `dns_opts:` back to the runner sidecar task, run the script, confirm it fails.
Then revert the change.

**Step 4: Commit**

```bash
git add tests/check_docker_tasks.py
git commit -m "Add Python structural validator for Docker task parameters"
```

---

### Task 2: Create Ansible regression playbook

**Files:**
- Create: `tests/test-regression.yml`

**Step 1: Write the Ansible playbook**

This playbook runs on localhost (no remote host needed) and validates:
- Runs the Python structural checker (Task 1)
- Greps for hardcoded `/volume1/` paths in roles and templates
- Renders `app.ini.j2` with Tailscale test variables and validates output
- Renders `ts-serve-gitea.json.j2` with test variables and validates output

```yaml
---
# tests/test-regression.yml
#
# Regression test suite for Tailscale sidecar integration.
# Run with: ansible-playbook tests/test-regression.yml
# Requires: No Docker, no NAS, no secrets.
#
- name: Regression Tests
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    project_root: "{{ playbook_dir }}/.."
    roles_dir: "{{ project_root }}/playbooks/roles"
    templates_dir: "{{ project_root }}/playbooks/templates"
    # Test-only variables for template rendering (no real domains)
    test_tailnet: "test-tailnet.ts.net"
    test_gitea_domain: "gitea.test-tailnet.ts.net"
    test_gitea_protocol: "http"
    test_gitea_port: "8443"
    test_gitea_ssh_port: "22"
    test_gitea_root_url: "https://gitea.test-tailnet.ts.net/"
    test_gitea_ssh_domain: "gitea.test-tailnet.ts.net"
    test_serve_domain: "gitea.test-tailnet.ts.net"
    test_serve_proxy_port: "3000"

  tasks:
    # ================================================================
    # Check 1: Docker task structural validation (Gaps 1, 2, 4)
    # ================================================================
    - name: "CHECK 1: Run Docker task structural validator"
      command: python3 {{ project_root }}/tests/check_docker_tasks.py
      args:
        chdir: "{{ project_root }}"
      changed_when: false

    # ================================================================
    # Check 2: No hardcoded /volume1/ paths in roles (Gap 3)
    # ================================================================
    - name: "CHECK 2: Scan role tasks for hardcoded /volume1/ paths"
      shell: >
        grep -rn '/volume1/' {{ roles_dir }}/*/tasks/ {{ roles_dir }}/*/templates/
        || true
      register: hardcoded_paths_roles
      changed_when: false

    - name: "CHECK 2: Assert no hardcoded paths in roles"
      assert:
        that:
          - hardcoded_paths_roles.stdout == ""
        fail_msg: >
          Found hardcoded /volume1/ paths in role files (use {{ '{{' }} gitea_data_path {{ '}}' }} instead):
          {{ hardcoded_paths_roles.stdout }}

    - name: "CHECK 2: Scan playbooks for hardcoded /volume1/ paths (excluding vars)"
      shell: >
        grep -rn '/volume1/' {{ project_root }}/playbooks/*.yml
        --exclude='*/vars/*' --exclude='vars/main.yml'
        || true
      register: hardcoded_paths_playbooks
      changed_when: false

    - name: "CHECK 2: Assert no hardcoded paths in playbooks (excluding vars/main.yml)"
      assert:
        that:
          - hardcoded_paths_playbooks.stdout == ""
        fail_msg: >
          Found hardcoded /volume1/ paths in playbook files:
          {{ hardcoded_paths_playbooks.stdout }}

    # ================================================================
    # Check 3: app.ini.j2 renders correctly with Tailscale vars (Gap 5)
    # ================================================================
    - name: "CHECK 3: Render app.ini.j2 with Tailscale test variables"
      template:
        src: "{{ templates_dir }}/app.ini.j2"
        dest: "/tmp/test-app-ini-rendered"
      vars:
        gitea_protocol: "{{ test_gitea_protocol }}"
        gitea_domain: "{{ test_gitea_domain }}"
        gitea_root_url: "{{ test_gitea_root_url }}"
        gitea_port: "{{ test_gitea_port }}"
        gitea_ssh_port: "{{ test_gitea_ssh_port }}"
        gitea_ssh_domain: "{{ test_gitea_ssh_domain }}"
        gitea_db_name: "test_db"
        gitea_db_user: "test_user"
        gitea_db_password: "test_pass"
        gitea_jwt_secret: "test_jwt_secret_value"

    - name: "CHECK 3: Read rendered app.ini"
      slurp:
        src: /tmp/test-app-ini-rendered
      register: rendered_ini

    - name: "CHECK 3: Decode rendered app.ini"
      set_fact:
        ini_content: "{{ rendered_ini.content | b64decode }}"

    - name: "CHECK 3: Assert app.ini PROTOCOL is http"
      assert:
        that:
          - "'PROTOCOL = http' in ini_content"
        fail_msg: "app.ini should have PROTOCOL = http when Tailscale handles TLS, got: {{ ini_content }}"

    - name: "CHECK 3: Assert app.ini ROOT_URL uses tailnet domain"
      assert:
        that:
          - "'https://gitea.test-tailnet.ts.net/' in ini_content"
        fail_msg: "app.ini ROOT_URL should use the tailnet domain"

    - name: "CHECK 3: Assert app.ini has no CERT_FILE in http mode"
      assert:
        that:
          - "'CERT_FILE' not in ini_content"
        fail_msg: "app.ini should not have CERT_FILE when PROTOCOL = http"

    - name: "CHECK 3: Assert app.ini has no KEY_FILE in http mode"
      assert:
        that:
          - "'KEY_FILE' not in ini_content"
        fail_msg: "app.ini should not have KEY_FILE when PROTOCOL = http"

    - name: "CHECK 3: Assert app.ini SSH_DOMAIN uses tailnet"
      assert:
        that:
          - "'SSH_DOMAIN = gitea.test-tailnet.ts.net' in ini_content"
        fail_msg: "app.ini SSH_DOMAIN should use the tailnet domain"

    # ================================================================
    # Check 4: ts-serve-gitea.json.j2 renders correctly (Gap 5)
    # ================================================================
    - name: "CHECK 4: Render ts-serve-gitea.json.j2"
      template:
        src: "{{ roles_dir }}/tailscale_sidecar/templates/ts-serve-gitea.json.j2"
        dest: "/tmp/test-ts-serve-rendered.json"
      vars:
        tailscale_serve_domain: "{{ test_serve_domain }}"
        tailscale_serve_proxy_port: "{{ test_serve_proxy_port }}"

    - name: "CHECK 4: Read rendered ts-serve config"
      slurp:
        src: /tmp/test-ts-serve-rendered.json
      register: rendered_serve

    - name: "CHECK 4: Decode ts-serve config"
      set_fact:
        serve_content: "{{ rendered_serve.content | b64decode }}"

    - name: "CHECK 4: Assert ts-serve config is valid JSON"
      set_fact:
        serve_json: "{{ serve_content | from_json }}"

    - name: "CHECK 4: Assert ts-serve proxies to correct port"
      assert:
        that:
          - "'http://127.0.0.1:3000' in serve_content"
        fail_msg: "ts-serve config should proxy to http://127.0.0.1:3000"

    - name: "CHECK 4: Assert ts-serve uses tailnet domain"
      assert:
        that:
          - "'gitea.test-tailnet.ts.net' in serve_content"
        fail_msg: "ts-serve config should reference the tailnet domain"

    # ================================================================
    # Cleanup
    # ================================================================
    - name: Clean up rendered test files
      file:
        path: "{{ item }}"
        state: absent
      loop:
        - /tmp/test-app-ini-rendered
        - /tmp/test-ts-serve-rendered.json
```

**Step 2: Run the playbook to verify it passes**

Run: `ansible-playbook tests/test-regression.yml`
Expected: All tasks OK (green), 0 failures

**Step 3: Commit**

```bash
git add tests/test-regression.yml
git commit -m "Add Ansible regression playbook for template and path checks"
```

---

### Task 3: Add Makefile target

**Files:**
- Modify: `Makefile`

**Step 1: Add the test target**

Add to the end of the Makefile, before the `help` target:

```makefile
.PHONY: test
test: ## Run regression test suite (no Docker/NAS required)
	@echo "Running regression tests..."
	@ansible-playbook tests/test-regression.yml
```

**Step 2: Run it**

Run: `make test`
Expected: All tests pass

**Step 3: Verify `make help` shows the new target**

Run: `make help`
Expected: Shows `test` with description

**Step 4: Commit**

```bash
git add Makefile
git commit -m "Add 'make test' target for regression tests"
```

---

### Task 4: Add CI workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Step 1: Write the workflow**

```yaml
name: Regression Tests

on:
  push:
    branches: [main, "feature/*"]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Run Regression Tests
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install Ansible
        run: pip install ansible

      - name: Run regression tests
        run: ansible-playbook tests/test-regression.yml
```

**Step 2: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "Add CI workflow for regression tests"
```

---

### Task 5: Push and verify

**Step 1: Push all commits**

```bash
git push github feature/tailnet
```

**Step 2: Verify CI passes**

Check the GitHub Actions "Regression Tests" workflow runs and passes on the PR.
