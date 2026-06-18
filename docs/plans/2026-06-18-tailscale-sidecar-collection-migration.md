# Tailscale Sidecar → `jaxzin.infra` Collection Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the local `playbooks/roles/tailscale_sidecar` role with the published `jaxzin.infra.tailscale_sidecar` role (pinned to `1.6.0`), delete the local copy, map the existing variables, and keep the regression suite green.

**Architecture:** The bootstrap stops carrying its own Tailscale sidecar role. It pins the `jaxzin.infra` collection in `playbooks/galaxy-requirements.yml` (already installed at deploy time by `dawidd6/action-ansible-playbook`'s `requirements:` input and the `make install-ansible-collections` target), and `gitea-deploy.yml` includes the collection role by its fully-qualified name (`jaxzin.infra.tailscale_sidecar`). The one bootstrap-specific asset — the Serve config template that adds the tailnet-side SSH TCP forward — moves from the deleted role into `playbooks/templates/` and is passed to the collection role by absolute path. The regression suite drops the checks that asserted the *local role's internals* (now owned and molecule-tested by the collection) and gains a single migration-contract check.

**Tech Stack:** Ansible (ansible-core ≥ 2.15), `community.docker` (≥ 3.0.0), `jaxzin.infra` collection `1.6.0`, Python 3 (stdlib) for `tests/check_docker_tasks.py`, Tailscale sidecar container on Synology DSM Docker.

## Global Constraints

- **Pin the collection at `1.6.0`.** This is the first release containing all three parity features named in issue #128: DNS self-heal/watchdog (1.4.0), expired/revoked auth-key fail-fast (1.5.0), and opt-in userspace networking (1.6.0). Use exactly `version: "1.6.0"`.
- **The collection role has no internal `tailscale_enabled`.** Gate the role include at the playbook level with `when: tailscale_enabled | bool` to preserve the no-op-in-tests behaviour.
- **Set `tailscale_assert_tailnet_route: true` for the Gitea sidecar.** It proxies outbound; the collection defaults this `false` (Serve-only). True preserves the existing "registered but NOT routing → ENETUNREACH" guard.
- **Never hardcode domains or secrets.** Domains/topology come from env lookups in `playbooks/vars/main.yml` (`TS_TAILNET`, `NAS_HOST`, `GITEA_LAN_HOST`, …). Do not introduce literal domains/IPs anywhere in committed config.
- **No hardcoded `/volume1/` paths in role tasks/templates or in `playbooks/*.yml`.** Use the `gitea_data_path`-derived variables. `tests/test-regression.yml` CHECK 2 enforces this.
- **The regression suite must run with no Docker, no NAS, no secrets, and no network.** It only reads/renders files. Do not add a runtime dependency on the installed collection to `tests/test-regression.yml` (the `Regression Tests` CI job installs only `ansible`, not galaxy collections, and never runs `gitea-deploy.yml`).
- **The collection's failure messages are now generic.** After migration the private runbook pointer (`docs/runbooks/tailscale-authkey-rotation.md`) and the Gitea #25 reference disappear from fail-fast/assert output. Re-surfacing them (a thin wrapper, or an upstream `tailscale_authkey_runbook_url`) is **out of scope** for this plan; the runbook file itself stays in the repo.

---

## File Structure

| Path | Action | Responsibility |
|------|--------|----------------|
| `playbooks/templates/ts-serve-gitea.json.j2` | **Create** (move from role) | Bootstrap-specific Tailscale Serve config: HTTPS Web handler + tailnet-side SSH TCP forward. Rendered by the collection role via `tailscale_serve_config_src`. |
| `playbooks/galaxy-requirements.yml` | **Modify** | Add `jaxzin.infra` pinned at `1.6.0` alongside `tafeen.synology`. |
| `playbooks/vars/main.yml` | **Modify** | Add `tailscale_gitea_dns_watchdog_dir` (host dir for the collection's DNS watchdog scratch script, inside the Gitea docker tree). |
| `playbooks/gitea-deploy.yml` | **Modify** | "Deploy Tailscale sidecar for Gitea" task: use the FQCN role, absolute Serve template path, new collection vars (`tailscale_assert_tailnet_route`, `tailscale_dns_watchdog_host_dir`), and a playbook-level `when: tailscale_enabled | bool` gate. |
| `playbooks/roles/tailscale_sidecar/` | **Delete** | The retired local role (`tasks/main.yml`, `templates/ts-serve-gitea.json.j2`, `meta/main.yml`). |
| `collections/ansible_collections/jaxzin/infra/` | **Delete** | Orphaned, stale vendored copy of the collection role (not on any active collections path; superseded by the galaxy pin). |
| `tests/test-regression.yml` | **Modify** | Repoint CHECK 4 at the relocated template; remove CHECK 6/14/15 (local-role internals, now the collection's concern); trim CHECK 17 to `gitea_server` only; add CHECK 18 (migration contract). |
| `tests/check_docker_tasks.py` | **Modify** | Remove Check B (`check_tailscale_sidecar`) and Check G (`check_g_tailscale_authkey_failfast`) and their now-dead constants — both read the deleted local-role task file. |
| `README.md` | **Modify** | File-tree: replace the `tailscale_sidecar/` role entry with a note that the sidecar now comes from the `jaxzin.infra` collection; add the relocated Serve template under `templates/`. |

**Verification commands (run from the repo root, no network/Docker needed):**
- `ansible-playbook tests/test-regression.yml` — runs the full regression suite, which itself invokes `python3 tests/check_docker_tasks.py` as CHECK 1.
- `make test` — same thing via the Makefile.

> A full `ansible-playbook --syntax-check playbooks/gitea-deploy.yml` requires the `jaxzin.infra` collection to be installed (via `make install-ansible-collections`, which needs galaxy access). That happens automatically in CI on the self-hosted runner. It is **not** required for the regression suite and is best-effort locally.

---

## Task 1: Relocate the Gitea Serve template into `playbooks/templates/`

Move the one bootstrap-specific asset out of the doomed role *before* deleting the role, and prove it still renders. The local role keeps working (the `template` module accepts an absolute `src`), so the suite stays green throughout this task.

**Files:**
- Create: `playbooks/templates/ts-serve-gitea.json.j2`
- Delete: `playbooks/roles/tailscale_sidecar/templates/ts-serve-gitea.json.j2`
- Modify: `playbooks/gitea-deploy.yml` (the `tailscale_serve_config_src` line only)
- Modify: `tests/test-regression.yml:148` (CHECK 4 render path)
- Test: `tests/test-regression.yml` (CHECK 4)

**Interfaces:**
- Produces: `playbooks/templates/ts-serve-gitea.json.j2`, referenceable as `{{ playbook_dir }}/templates/ts-serve-gitea.json.j2` from `gitea-deploy.yml` and as `{{ templates_dir }}/ts-serve-gitea.json.j2` from the regression suite (`templates_dir = {{ project_root }}/playbooks/templates`).
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Point CHECK 4 at the new template location (failing test first)**

In `tests/test-regression.yml`, change the CHECK 4 render `src` from the role path to the templates dir. Find:

```yaml
    - name: "CHECK 4: Render ts-serve-gitea.json.j2"
      template:
        src: "{{ roles_dir }}/tailscale_sidecar/templates/ts-serve-gitea.json.j2"
        dest: "/tmp/test-ts-serve-rendered.json"
```

Replace the `src:` line so the block reads:

```yaml
    - name: "CHECK 4: Render ts-serve-gitea.json.j2"
      template:
        src: "{{ templates_dir }}/ts-serve-gitea.json.j2"
        dest: "/tmp/test-ts-serve-rendered.json"
```

Leave the rest of CHECK 4 (the slurp/decode/assert tasks) unchanged.

- [ ] **Step 2: Run the suite to verify CHECK 4 now fails**

Run: `ansible-playbook tests/test-regression.yml`
Expected: FAIL at "CHECK 4: Render ts-serve-gitea.json.j2" with a "Could not find or access" / file-not-found error for `playbooks/templates/ts-serve-gitea.json.j2` (the template hasn't moved yet).

- [ ] **Step 3: Create the relocated template (verbatim copy)**

Create `playbooks/templates/ts-serve-gitea.json.j2` with exactly this content (a byte-for-byte copy of the current role template):

```jinja
{
  "TCP": {
    "443": {
      "HTTPS": true
    }{% if tailscale_serve_ssh_enabled | default(false) | bool %},
    "22": {
      "TCPForward": "{{ tailscale_serve_ssh_forward_host | default('127.0.0.1') }}:{{ tailscale_serve_ssh_forward_port | default('22') }}"
    }{% endif %}
  },
  "Web": {
    "{{ tailscale_serve_domain }}:443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:{{ tailscale_serve_proxy_port }}"
        }
      }
    }
  }
}
```

- [ ] **Step 4: Delete the old template copy from the role**

Run: `git rm playbooks/roles/tailscale_sidecar/templates/ts-serve-gitea.json.j2`
Expected: the file is staged for deletion. (The role's `tasks/main.yml` and `meta/main.yml` remain for now — Task 2 deletes the rest of the role.)

- [ ] **Step 5: Repoint the playbook's `tailscale_serve_config_src` at the absolute template path**

In `playbooks/gitea-deploy.yml`, inside the "Deploy Tailscale sidecar for Gitea" task, change:

```yaml
        tailscale_serve_config_src: "ts-serve-gitea.json.j2"
```

to:

```yaml
        # Absolute path so any role's template lookup resolves it regardless
        # of the role's own templates/ search path (Task 2 swaps this include
        # to the jaxzin.infra collection role, whose templates/ dir does not
        # carry this bootstrap-specific Serve config).
        tailscale_serve_config_src: "{{ playbook_dir }}/templates/ts-serve-gitea.json.j2"
```

- [ ] **Step 6: Run the suite to verify it is green again**

Run: `ansible-playbook tests/test-regression.yml`
Expected: PASS — "play recap" shows `failed=0`. CHECK 4 now renders from `playbooks/templates/` and its assertions (proxy `http://127.0.0.1:3000`, tailnet domain) pass.

- [ ] **Step 7: Commit**

```bash
git add playbooks/templates/ts-serve-gitea.json.j2 playbooks/gitea-deploy.yml tests/test-regression.yml
git rm --cached --ignore-unmatch playbooks/roles/tailscale_sidecar/templates/ts-serve-gitea.json.j2
git commit -m "refactor(tailscale): move ts-serve-gitea template to playbooks/templates"
```

---

## Task 2: Consume `jaxzin.infra.tailscale_sidecar`, delete the local role, update the suite

The irreducible migration. The regression suite's role-internal checks read files that this task deletes, so the test edits and the migration must land together. This task follows TDD at the suite level: first edit the tests to encode the post-migration contract (red — the new CHECK 18 fails), then perform the migration (green).

**Files:**
- Modify: `playbooks/galaxy-requirements.yml`
- Modify: `playbooks/vars/main.yml`
- Modify: `playbooks/gitea-deploy.yml` (the "Deploy Tailscale sidecar for Gitea" task)
- Delete: `playbooks/roles/tailscale_sidecar/` (whole directory)
- Delete: `collections/ansible_collections/jaxzin/infra/` (orphaned vendored copy)
- Modify: `tests/test-regression.yml` (remove CHECK 6/14/15, trim CHECK 17, add CHECK 18)
- Modify: `tests/check_docker_tasks.py` (remove Check B and Check G)
- Modify: `README.md`
- Test: `tests/test-regression.yml` (CHECK 18)

**Interfaces:**
- Consumes: `playbooks/templates/ts-serve-gitea.json.j2` (from Task 1).
- Produces: a `gitea-deploy.yml` that includes `jaxzin.infra.tailscale_sidecar`; a `tests/test-regression.yml` whose CHECK 18 asserts the migration contract: `'jaxzin.infra.tailscale_sidecar' in gitea_deploy`, `'name: tailscale_sidecar' not in gitea_deploy`, `'tailscale_assert_tailnet_route: true' in gitea_deploy`, `'when: tailscale_enabled | bool' in gitea_deploy`, `'tailscale_dns_watchdog_host_dir' in gitea_deploy`, `'jaxzin.infra' in galaxy_requirements`, `'1.6.0' in galaxy_requirements`, and that both `playbooks/roles/tailscale_sidecar` and `collections/ansible_collections/jaxzin/infra` no longer exist.

### Part A — Encode the post-migration contract in the tests (red)

- [ ] **Step 1: Remove CHECK 6 (local-role userspace-gating asserts)**

In `tests/test-regression.yml`, delete the entire CHECK 6 block — the section header comment, the slurp + decode of `tailscale_sidecar/tasks/main.yml` (which defines the `tailscale_sidecar_tasks` fact), and all three CHECK 6 asserts. That is, remove every line from:

```yaml
    # ================================================================
    # Check 6: tailscale_sidecar role correctly gates userspace env vars
    # ================================================================
```

through the end of the last CHECK 6 task:

```yaml
    - name: "CHECK 6: Assert TS_USERSPACE env is wired to the variable"
      assert:
        that:
          - "'TS_USERSPACE' in tailscale_sidecar_tasks"
        fail_msg: >
          tailscale_sidecar/tasks/main.yml must export TS_USERSPACE so
          consumers can opt into userspace mode.
```

(Userspace mode is now implemented and molecule-tested in the collection; the bootstrap no longer owns those internals. Removing this block also removes the `tailscale_sidecar_tasks` fact that CHECK 14/15/17 reused.)

- [ ] **Step 2: Remove CHECK 14 (local-role resolv.conf restore asserts)**

In `tests/test-regression.yml`, delete the entire CHECK 14 block — from its header:

```yaml
    # ================================================================
    # Check 14: Tailscale sidecar restores Docker embedded DNS resolver
    #           (127.0.0.11) after tailscaled writes resolv.conf.
    # ================================================================
```

through the end of its single assert task:

```yaml
    - name: "CHECK 14: Assert tailscale_sidecar restores 127.0.0.11 in resolv.conf"
      assert:
        that:
          - "'nameserver 127.0.0.11' in tailscale_sidecar_tasks"
          - "'Restore Docker embedded DNS resolver' in tailscale_sidecar_tasks"
          - "'if not (tailscale_accept_dns' not in tailscale_sidecar_tasks"
        fail_msg: >
          ...
          (2026-05-25 incident).
```

(The collection's DNS watchdog owns resolv.conf reconciliation now.)

- [ ] **Step 3: Remove CHECK 15 (local-role healthcheck self-heal asserts)**

In `tests/test-regression.yml`, delete the entire CHECK 15 block — from its header:

```yaml
    # ================================================================
    # Check 15: Tailscale sidecar self-heals resolv.conf continuously,
    #           not just at deploy time.
    # ================================================================
```

through the end of its single assert task:

```yaml
    - name: "CHECK 15: Assert tailscale_sidecar healthcheck self-heals resolv.conf"
      assert:
        that:
          - "'healthcheck:' in tailscale_sidecar_tasks"
          - "'/tmp/resolv_new' in tailscale_sidecar_tasks"
        fail_msg: >
          ...
          resolution (2026-06-05 incident).
```

(The collection implements the watchdog as a bind-mounted `dns-watchdog.sh` healthcheck + post-deploy reconcile — a different but behaviourally-equivalent shape, with no `/tmp/resolv_new` signature. Asserting the bootstrap's old inline shape would be wrong.)

- [ ] **Step 4: Trim CHECK 17 to `gitea_server` only**

In `tests/test-regression.yml`, CHECK 17 currently asserts json-file logging on both `gitea_server_tasks` and the now-removed `tailscale_sidecar_tasks` fact. Replace the whole CHECK 17 block (header comment + the assert task) with this `gitea_server`-only version:

```yaml
    # ================================================================
    # Check 17: Gitea-stack containers pin the json-file log driver,
    #           never the Synology `db` driver.
    # ================================================================
    # The Synology ContainerManager default `db` log driver wedges
    # (locks/hangs). A wedged driver makes Docker unable to run healthcheck
    # execs (container flips unhealthy) and unable to (re)start containers
    # ("failed to initialize logging driver"), so autoheal's restart leaves
    # them dead — a recurring NAS-wide outage (2026-06-15 incident; also
    # 2026-06-05). Every long-lived gitea-stack container managed HERE must
    # pin log_driver: json-file explicitly. The Tailscale sidecar is now
    # deployed by jaxzin.infra.tailscale_sidecar, which defaults
    # tailscale_log_driver: json-file (the collection owns that guarantee).
    # Reuses gitea_server_tasks (decoded in CHECK 16).
    - name: "CHECK 17: Assert gitea-stack containers pin json-file logging"
      assert:
        that:
          # gitea-db, gitea (sidecar variant), gitea (standalone variant) =
          # 3 occurrences in gitea_server; allow >=3 for future containers.
          - "gitea_server_tasks.split('log_driver: json-file') | length - 1 >= 3"
          # Guard the anti-pattern: no container may pin the wedge-prone db driver.
          - "'log_driver: db' not in gitea_server_tasks"
        fail_msg: >
          Every long-lived gitea-stack container managed in gitea_server
          (gitea-db, gitea) must set 'log_driver: json-file'. The Synology
          default 'db' log driver wedges and breaks healthchecks + restarts,
          taking the whole stack down (2026-06-15 incident).
```

- [ ] **Step 5: Add CHECK 18 (migration contract)**

In `tests/test-regression.yml`, immediately *before* the final "Cleanup" section:

```yaml
    # ================================================================
    # Cleanup
    # ================================================================
```

insert this new CHECK 18 block:

```yaml
    # ================================================================
    # Check 18: the Tailscale sidecar is deployed by the pinned
    #           jaxzin.infra collection role, not a local copy (#128)
    # ================================================================
    # The local playbooks/roles/tailscale_sidecar was retired in favour of
    # jaxzin.infra.tailscale_sidecar (pinned). This check locks in the
    # migration contract: the playbook includes the FQCN role (never the bare
    # local name), gates it at play level (the collection role has no internal
    # tailscale_enabled), preserves the outbound-route assert + DNS watchdog
    # wiring, the collection is pinned in galaxy-requirements, and neither the
    # local role nor the stale vendored collection copy survive.
    - name: "CHECK 18: Read gitea-deploy.yml + galaxy-requirements.yml"
      slurp:
        src: "{{ item }}"
      register: migration_sources_raw
      loop:
        - "{{ project_root }}/playbooks/gitea-deploy.yml"
        - "{{ project_root }}/playbooks/galaxy-requirements.yml"

    - name: "CHECK 18: Decode migration sources"
      set_fact:
        migration_deploy: "{{ migration_sources_raw.results[0].content | b64decode }}"
        migration_galaxy: "{{ migration_sources_raw.results[1].content | b64decode }}"

    - name: "CHECK 18: Assert the playbook consumes the pinned collection role"
      assert:
        that:
          - "'jaxzin.infra.tailscale_sidecar' in migration_deploy"
          - "'name: tailscale_sidecar' not in migration_deploy"
          - "'tailscale_assert_tailnet_route: true' in migration_deploy"
          - "'tailscale_dns_watchdog_host_dir' in migration_deploy"
          - "'when: tailscale_enabled | bool' in migration_deploy"
          - "'jaxzin.infra' in migration_galaxy"
          - "'1.6.0' in migration_galaxy"
        fail_msg: >
          gitea-deploy.yml must include jaxzin.infra.tailscale_sidecar (FQCN,
          never the bare local 'name: tailscale_sidecar'), set
          tailscale_assert_tailnet_route: true and tailscale_dns_watchdog_host_dir
          for the Gitea sidecar, gate the include with
          'when: tailscale_enabled | bool', and galaxy-requirements.yml must pin
          jaxzin.infra at 1.6.0 (#128).

    - name: "CHECK 18: Assert the local role is deleted"
      stat:
        path: "{{ roles_dir }}/tailscale_sidecar"
      register: local_sidecar_role_stat

    - name: "CHECK 18: Assert the stale vendored collection copy is deleted"
      stat:
        path: "{{ project_root }}/collections/ansible_collections/jaxzin/infra"
      register: vendored_collection_stat

    - name: "CHECK 18: Assert both retired copies are gone"
      assert:
        that:
          - not local_sidecar_role_stat.stat.exists
          - not vendored_collection_stat.stat.exists
        fail_msg: >
          The retired local role (playbooks/roles/tailscale_sidecar) and the
          stale vendored collection copy
          (collections/ansible_collections/jaxzin/infra) must both be deleted —
          the sidecar now comes from the pinned jaxzin.infra collection (#128).
```

- [ ] **Step 6: Remove Check B and Check G from `check_docker_tasks.py`**

`tests/check_docker_tasks.py` Check B (`check_tailscale_sidecar`) and Check G (`check_g_tailscale_authkey_failfast`) both read `playbooks/roles/tailscale_sidecar/tasks/main.yml`, which Part B deletes. Remove them now (this file is invoked by the regression suite as CHECK 1).

(a) In the module docstring, delete these two bullet lines:

```python
  B) tailscale_sidecar container task must include TS_ACCEPT_DNS env var
```
```python
  G) tailscale_sidecar role must fail fast with an auth-aware message on an
     expired/revoked TS_AUTHKEY and assert a usable tailnet route, not just
     BackendState==Running (regression lock-in — see Gitea issue #25)
```

(b) Delete the now-dead module constants:

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

(c) Delete the entire `check_tailscale_sidecar` function (the `def check_tailscale_sidecar(errors):` block, docstring "Check B: ...", through its final `errors.append(...)` for "No docker_container task found").

(d) Delete the entire `check_g_tailscale_authkey_failfast` function (the `def check_g_tailscale_authkey_failfast(errors):` block through its final `errors.append(...)`).

(e) In `main()`, delete these two call sites (comment + call each):

```python
    # Run check B on tailscale_sidecar specifically
    check_tailscale_sidecar(errors)
```
```python
    # Run check G: tailscale_sidecar must fail fast on a dead TS_AUTHKEY (#25)
    check_g_tailscale_authkey_failfast(errors)
```

Leave Check D (`check_d_gitea_sidecar_host_ports`) untouched — it reads `gitea-deploy.yml` for the "Deploy Tailscale sidecar for Gitea" task's `tailscale_host_ports`, which the migration preserves.

- [ ] **Step 7: Run the suite to confirm a clean red on CHECK 18 only**

Run: `ansible-playbook tests/test-regression.yml`
Expected: FAIL at the first CHECK 18 assert ("CHECK 18: Assert the playbook consumes the pinned collection role"), because the playbook still uses the bare local role and `galaxy-requirements.yml` has no `jaxzin.infra` pin. CHECK 1 (the now-trimmed `check_docker_tasks.py`) and every other check up to CHECK 18 must PASS — confirming the test edits are internally consistent and nothing references the (still-present) local role internals anymore.

### Part B — Perform the migration (green)

- [ ] **Step 8: Pin the collection in `galaxy-requirements.yml`**

Replace the entire contents of `playbooks/galaxy-requirements.yml` with:

```yaml
---
collections:
  - name: tafeen.synology
    version: "1.0.1"
  - name: jaxzin.infra
    version: "1.6.0"
```

- [ ] **Step 9: Add the watchdog host-dir variable to `vars/main.yml`**

In `playbooks/vars/main.yml`, in the "Tailscale sidecar configuration" section, add a line after `tailscale_gitea_serve_config_dir`:

```yaml
tailscale_gitea_serve_config_dir: "{{ tailscale_data_path }}/gitea-serve-config"
# Host dir for the collection role's DNS-watchdog scratch script
# (dns-watchdog.sh). Kept inside the Gitea docker tree, a sibling of the
# sidecar's state + serve dirs. Verifies the issue #128 migration note that
# tailscale_dns_watchdog_host_dir lands in the expected docker tree.
tailscale_gitea_dns_watchdog_dir: "{{ tailscale_data_path }}/gitea-dns-watchdog"
```

- [ ] **Step 10: Switch the playbook include to the collection role + new vars + gate**

In `playbooks/gitea-deploy.yml`, replace the whole "Deploy Tailscale sidecar for Gitea" task (the `- name: Deploy Tailscale sidecar for Gitea` block, from its `- name:` line through the end of the `tailscale_host_ports` list) with this block. It keeps every existing var and comment, swaps the role name to the FQCN, adds the two new collection vars, and adds the play-level enable gate:

```yaml
    - name: Deploy Tailscale sidecar for Gitea
      include_role:
        name: jaxzin.infra.tailscale_sidecar
      vars:
        tailscale_container_name: "{{ tailscale_gitea_container_name }}"
        tailscale_hostname: "{{ tailscale_gitea_hostname }}"
        tailscale_state_dir: "{{ tailscale_gitea_state_dir }}"
        tailscale_serve_enabled: true
        # Absolute path so the collection role's template lookup resolves this
        # bootstrap-specific Serve config (the collection's own templates/ dir
        # ships only the generic ts-serve.json.j2, which lacks the tailnet-side
        # SSH TCP forward below).
        tailscale_serve_config_src: "{{ playbook_dir }}/templates/ts-serve-gitea.json.j2"
        tailscale_serve_config_dir: "{{ tailscale_gitea_serve_config_dir }}"
        tailscale_serve_domain: "{{ gitea_domain }}"
        tailscale_serve_proxy_port: "3000"
        # Keep the collection's DNS-watchdog scratch dir inside the Gitea
        # docker tree (issue #128 migration note).
        tailscale_dns_watchdog_host_dir: "{{ tailscale_gitea_dns_watchdog_dir }}"
        # This sidecar proxies outbound, so preserve the "registered but NOT
        # routing -> ENETUNREACH" guard. The collection defaults this false
        # for Serve-only sidecars (issue #128 migration note).
        tailscale_assert_tailnet_route: true
        # true: tailscaled applies the tailnet's global nameservers (Cloudflare
        # 1.1.1.1 via "Override DNS servers" in the admin console) as upstream
        # forwarders for 100.100.100.100. This gives the container all three:
        # tailnet names (MagicDNS direct), external names (Cloudflare upstream),
        # and lan.jaxzin.com (Split DNS → 192.168.10.1). false would opt out of
        # the upstream config, leaving 100.100.100.100 with no forwarder and
        # SERVFAILing on external names — which silently blocks Let's Encrypt
        # ACME cert renewal (2026-05-25 incident).
        tailscale_accept_dns: true
        tailscale_serve_ssh_enabled: true
        tailscale_serve_ssh_forward_host: "127.0.0.1"
        tailscale_serve_ssh_forward_port: "{{ gitea_ssh_listen_port }}"
        tailscale_host_ports:
          - "127.0.0.1:{{ gitea_port }}:3000"
          # Container-side port is Gitea's actual SSH listener
          # (gitea_ssh_listen_port = 2222), NOT :22. Inside the shared netns,
          # :22 is bound by Tailscale Serve on the tailnet IP only (for the
          # tailnet-side ssh://git@gitea.<tailnet>:22/... flow). LAN traffic
          # arriving on :22 finds no matching listener and gets RST. Gitea
          # itself listens on :::2222 (app.ini SSH_LISTEN_PORT). Same variable
          # as tailscale_serve_ssh_forward_port keeps both paths consistent.
          - "{{ gitea_lan_host }}:{{ gitea_lan_ssh_port }}:{{ gitea_ssh_listen_port }}"
      # The collection role has no internal tailscale_enabled; gate the include
      # at play level so the role is a no-op when Tailscale is disabled
      # (issue #128 migration note).
      when: tailscale_enabled | bool
```

- [ ] **Step 11: Delete the local role**

Run: `git rm -r playbooks/roles/tailscale_sidecar`
Expected: `tasks/main.yml` and `meta/main.yml` are staged for deletion (the template was already removed in Task 1).

- [ ] **Step 12: Delete the orphaned vendored collection copy**

Run: `git rm -r collections/ansible_collections/jaxzin/infra`
Expected: the stale `roles/tailscale_sidecar/tasks/main.yml` under the vendored tree is staged for deletion. If that leaves `collections/` empty, also run `git status` to confirm no other tracked files remain under `collections/` (there are none — only this single vendored file was tracked).

- [ ] **Step 13: Update the README file-tree**

In `README.md`, in the directory-tree block, replace the role line and add the relocated template. Change:

```
│   ├── gitea_server/           # Gitea server + MySQL deployment
│   └── tailscale_sidecar/      # Reusable Tailscale sidecar container
├── templates/
│   └── app.ini.j2              # Gitea configuration template
```

to:

```
│   └── gitea_server/           # Gitea server + MySQL deployment
├── templates/
│   ├── app.ini.j2              # Gitea configuration template
│   └── ts-serve-gitea.json.j2  # Tailscale Serve config for the Gitea sidecar
```

(The Tailscale sidecar role now comes from the pinned `jaxzin.infra` collection — `playbooks/galaxy-requirements.yml` — not a local role. The narrative in "How It Works" still describes the same kernel-mode, namespace-shared sidecar and needs no change.)

- [ ] **Step 14: Run the suite to verify green**

Run: `ansible-playbook tests/test-regression.yml`
Expected: PASS — "play recap" shows `failed=0`. CHECK 18 now passes (FQCN include present, `1.6.0` pinned, both retired copies gone), CHECK 1 (`check_docker_tasks.py`) passes without Checks B/G, and CHECK 4/9/17 stay green.

- [ ] **Step 15: Best-effort full syntax check (skip if galaxy is unreachable)**

Run:
```bash
make install-ansible-collections && ansible-playbook --syntax-check playbooks/gitea-deploy.yml
```
Expected: with the `jaxzin.infra` 1.6.0 collection installed, the playbook parses and resolves `jaxzin.infra.tailscale_sidecar`. If `ansible-galaxy` cannot reach `galaxy.ansible.com` in this environment, skip this step — CI installs the collection on the self-hosted runner. Do **not** block the commit on it.

- [ ] **Step 16: Commit**

```bash
git add playbooks/galaxy-requirements.yml playbooks/vars/main.yml playbooks/gitea-deploy.yml \
        tests/test-regression.yml tests/check_docker_tasks.py README.md
git rm -r --cached --ignore-unmatch playbooks/roles/tailscale_sidecar collections/ansible_collections/jaxzin/infra
git commit -m "feat(tailscale): consume jaxzin.infra.tailscale_sidecar 1.6.0, retire local role (#128)"
```

---

## Self-Review

**1. Spec coverage** (issue #128 acceptance + migration notes):

- ✅ *"Bootstrap deploys the sidecar via `jaxzin.infra.tailscale_sidecar` (pinned)"* — Task 2 Steps 8 & 10 (pin `1.6.0`, FQCN include); CHECK 18 locks it in.
- ✅ *"`playbooks/roles/tailscale_sidecar/` deleted"* — Task 2 Step 11; CHECK 18 asserts non-existence.
- ✅ *"CI / molecule green"* — regression suite (`test.yml`) is the bootstrap's CI gate; Tasks 1 & 2 end on green. Molecule lives in the collection, not this repo.
- ✅ *DNS watchdog shape differs / verify `tailscale_dns_watchdog_host_dir`* — Step 9 adds `tailscale_gitea_dns_watchdog_dir` under the Gitea docker tree; Step 10 passes it; CHECK 18 asserts it is wired.
- ✅ *Failure messages now generic; runbook pointer disappears* — Global Constraints record this as an accepted, out-of-scope tradeoff (runbook file retained); Step 6 drops the now-invalid `check_g` marker assertion (which required the runbook path in the message).
- ✅ *Set `tailscale_assert_tailnet_route: true` for the Gitea sidecar* — Step 10; CHECK 18 asserts it.
- ✅ *Gate the role include with `when: tailscale_enabled`* — Step 10 (`when: tailscale_enabled | bool`); CHECK 18 asserts it.
- ✅ *Map the existing vars* — Step 10 maps every consumer var to the collection's authoritative names (`tailscale_container_name`, `tailscale_hostname`, `tailscale_state_dir`, `tailscale_serve_enabled`, `tailscale_serve_config_src`, `tailscale_serve_config_dir`, `tailscale_serve_domain`, `tailscale_serve_proxy_port`, `tailscale_accept_dns`, `tailscale_host_ports`); the `tailscale_serve_ssh_*` vars are consumed only by the bootstrap's own template (not collection options), so they carry over unchanged.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows the literal content. The only conditional step (Step 15) is explicitly best-effort with a stated skip condition.

**3. Type/name consistency:**
- Collection variable names verified against `jaxzin.infra` 1.6.0 `defaults/main.yml` and `meta/main.yml`: `tailscale_assert_tailnet_route` (default false), `tailscale_dns_watchdog_host_dir` (default `{{ tailscale_state_dir | dirname }}/tailscale-dns-watchdog`), `tailscale_serve_proxy_port`, `tailscale_accept_dns`, `tailscale_serve_config_src`/`_dir`/`_domain` — all consistent with Step 10.
- CHECK 18 discriminators are exact substrings of the Step 8/9/10 edits: `'jaxzin.infra.tailscale_sidecar'`, `'name: tailscale_sidecar'` (absent — FQCN line is `name: jaxzin.infra.tailscale_sidecar`), `'when: tailscale_enabled | bool'` (distinct from the pre-existing `when: tailscale_enabled | default(false) | bool` on the authkey-validation task), `'1.6.0'`.
- The `tailscale_sidecar_tasks` fact is defined only in CHECK 6 and reused by CHECK 14/15/17; Steps 1–4 remove every definition and use together, leaving no dangling reference.
- `check_docker_tasks.py` after Step 6: `TAILSCALE_SIDECAR_TASKS`/`AUTHKEY_FAILFAST_MARKERS` are removed along with their only consumers (Check B/G); Check D (kept) does not use them.
