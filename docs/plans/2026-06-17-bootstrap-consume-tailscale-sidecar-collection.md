# Migrate bootstrap to consume `jaxzin.infra.tailscale_sidecar` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get the jaxzin.infra#7 DNS watchdog into production by switching `jaxzin-infra-bootstrap` to consume the `jaxzin.infra.tailscale_sidecar` role (v1.6.0) and deleting the divergent local copy at `playbooks/roles/tailscale_sidecar/`, eliminating the two-copy drift permanently.

**Architecture:** Re-vendor the collection at tag `1.6.0` into `collections/ansible_collections/jaxzin/infra/` (keeps the bootstrap DR-self-contained — no network fetch at deploy time, consistent with the bootstrap-layer/DR-first philosophy). Move the bootstrap's custom Serve template to `playbooks/templates/` so the collection role's `serve_config_src` render finds it. Switch the `include_role` in `gitea-deploy.yml` to the FQCN, guarded by `tailscale_enabled`. Repoint the bootstrap's path-based regression checks at the vendored collection role. Delete the local role. Verify offline (`make test`), then deploy and confirm the watchdog survives a sidecar restart (the real durable-fix proof).

**Tech Stack:** Ansible (`community.docker`), the `jaxzin.infra` collection v1.6.0, the bootstrap offline test suite (`make test` → `tests/test-regression.yml` + `tests/check_docker_tasks.py`), `act`-based deploy (`.gitea/workflows/deploy.yml` / `.github/workflows/bootstrap.yml`).

---

## Session handoff — current state (READ FIRST)

Written 2026-06-17. This plan is **not started** — no bootstrap files have been changed; the only artifact is this document. Pick up at Task 0.

- **⚠️ Production is fragile right now.** Gitea OIDC login works *only* because of a manual runtime recovery applied during the diagnosis session: inside the `tailscale-gitea` container,
  `tailscale set --accept-dns=false ; sleep 2 ; tailscale set --accept-dns=true`.
  This is **not persistent.** Any restart of the `tailscale-gitea` sidecar / the `gitea` netns / Container Manager / the NAS will re-break OIDC login with a **500** until either the bounce is re-applied or this plan is deployed. **If it breaks before this lands:** re-apply the bounce, or break-glass into Gitea as the local `openclaw` account (creds in OpenBao; use the local login form, not the SSO button) for admin access. Deploying this plan is what makes the fix durable.
- **The collection side is already done.** jaxzin.infra#7 is closed by PR #8 (merged ~2026-06-17 08:32 UTC); collection **latest release 1.6.0**; the watchdog `dns-watchdog.sh` first shipped in **1.4.0**; the collection contains only the `tailscale_sidecar` role.
- **NAS access mechanics** (verified this session — don't rediscover): `ssh nas-ts` (host `nas.forest-draconis.ts.net`) using the on-disk key `~/.ssh/nas_jaxzin_ed25519` with `-o IdentityAgent=none -o IdentitiesOnly=yes` (the 1Password SSH agent cannot sign non-interactively in a headless shell). Run docker as `jaxzin` (a member of the `docker` group): `export PATH=/usr/local/bin:$PATH; docker …` — **no sudo** (sudo prompts for a password). Relevant containers: `gitea`, `gitea-db`, `tailscale-gitea` (the sidecar; `gitea` shares its netns), `authentik-server/worker/redis/postgresql`, `authentik-tailscale`.
- **Root-cause evidence (already verified):** tailscaled logged `dns: resolver: forward: no upstream resolvers set, returning SERVFAIL`; after the accept-dns bounce it logged `dns: Set: {DefaultResolvers:[1.1.1.1 …]}` and resolution recovered. The funnel/Serve path kept working throughout (inbound needs no resolver) — only *outbound* DNS in the shared netns was dead, which is why Gitea couldn't fetch authentik's OIDC discovery doc. Full writeup in project memory `project_gitea_oidc_500_dns_servfail.md`.
- **Redaction:** never commit the literal tailnet name — use `<tailnet>`. Substitute it at runtime in the Task 7 verification commands.

---

## Background (read before starting)

- The bug, root cause, and recovery are in [jaxzin.infra#7](https://github.com/jaxzin/ansible-collection-infra/issues/7); the durable fix is PR #8 (released in collection **v1.4.0**, current latest **v1.6.0**).
- Production currently runs the **local** role `playbooks/roles/tailscale_sidecar/` (the deploy invokes it by bare name at `playbooks/gitea-deploy.yml:74-76`). It has the downstream resolv.conf self-heal but **not** the upstream watchdog, so a sidecar/host restart reintroduces the Gitea OIDC 500. Production is presently healthy only because of a manual runtime `tailscale set --accept-dns` bounce.
- The collection role v1.6.0 is a **clean superset**: it has the #7 watchdog (`dns-watchdog.sh`), the auth-key-expiry fail-fast + route asserts (gated by `tailscale_assert_tailnet_route`), userspace/kernel mode, Serve/host_ports, **and** `json-file` log-driver pinning (which also addresses the Synology `db` log-driver wedge incident).
- **Var-name parity confirmed:** the collection role uses the same `tailscale_container_name/hostname/state_dir/network_name/authkey/image` names. The bootstrap's `tailscale_serve_ssh_*` vars are consumed by the bootstrap's **own** `ts-serve-gitea.json.j2` template (lines 5-7), not by the role API, so they keep working when passed through `include_role`.

**Design decisions already approved (do not re-litigate):**
1. Full migration to the collection role + delete the local copy (not a quick port). Chosen by the operator on 2026-06-17.
2. Consume by **re-vendoring** tag `1.6.0` into `collections/`, not a Galaxy/git fetch (DR-self-contained).
3. Preserve the old local role's behavior where it diverges from collection defaults: set `tailscale_assert_tailnet_route: true` (Gitea makes outbound tailnet calls — authentik OIDC discovery — through this sidecar) and keep the sidecar's memory limit matching what is deployed today (Task 0 measures it).

---

## File Structure

| File | New/Modified/Deleted | Responsibility |
| --- | --- | --- |
| `collections/ansible_collections/jaxzin/infra/**` | Replace | Vendored collection at tag 1.6.0 (the canonical role + the `dns-watchdog.sh` fix). |
| `playbooks/templates/ts-serve-gitea.json.j2` | Move (from local role) | Custom Gitea Serve config; rendered by the collection role via `serve_config_src`. |
| `playbooks/gitea-deploy.yml` | Modify (~line 74) | Switch `include_role` to `jaxzin.infra.tailscale_sidecar`, guard with `when: tailscale_enabled`, add the three preserved vars. |
| `tests/check_docker_tasks.py` | Modify | Repoint `TAILSCALE_SIDECAR_TASKS` + Check B path at the vendored collection role; keep Checks B & G meaningful. |
| `tests/test-regression.yml` | Modify | Repoint CHECK 6 + the serve-template path at the vendored collection; add a CHECK that the #7 watchdog is wired. |
| `playbooks/roles/tailscale_sidecar/` | **Delete** | The divergent local copy — removed to kill the drift. |
| `ansible.cfg` (root) | Create-if-needed | Only if Task 0 finds the FQCN does not resolve; pin `collections_path = ./collections`. |

---

## Task 0: Pre-flight verification (read-only — GATES the whole plan)

No edits. Confirm the assumptions the irreversible steps depend on. If any check fails, STOP and report — do not proceed.

- [ ] **Step 1: Confirm v1.6.0 contains the watchdog fix**

```bash
cd /tmp && rm -rf aci && git clone --depth 1 --branch 1.6.0 https://github.com/jaxzin/ansible-collection-infra.git aci
test -f aci/roles/tailscale_sidecar/files/dns-watchdog.sh && echo "WATCHDOG OK"
grep -q "accept-dns=false" aci/roles/tailscale_sidecar/files/dns-watchdog.sh && echo "BOUNCE OK"
```
Expected: `WATCHDOG OK` and `BOUNCE OK`. If absent, pick the lowest tag ≥ 1.4.0 that has them and use that tag everywhere below.

- [ ] **Step 2: Confirm the role still honors an enable/skip toggle OR plan to guard at the call site**

```bash
grep -nE "tailscale_enabled|when:" aci/roles/tailscale_sidecar/tasks/main.yml | head
```
If `tailscale_enabled` gating is **absent** from the collection role (expected — it was a bootstrap-ism), that is fine: Task 3 guards the `include_role` with `when: tailscale_enabled | bool` so the bootstrap controls enablement at the call site. Note the result; no action here.

- [ ] **Step 3: Confirm FQCN resolution from the repo**

```bash
cd <repo-root>
ANSIBLE_COLLECTIONS_PATH=./collections ansible-doc -t role jaxzin.infra.tailscale_sidecar 2>&1 | head -5
```
Expected: role docs print (after Task 1 re-vendors; for now this may show the stale copy). Record whether `ansible-playbook playbooks/gitea-deploy.yml` (run from repo root) auto-includes `./collections` on its `collections_path`:
```bash
grep -rnE "collections_path|ANSIBLE_COLLECTIONS" ansible.cfg .gitea/workflows .github/workflows Makefile 2>/dev/null
```
If nothing pins it, Task 1 adds a root `ansible.cfg` with `collections_path = ./collections`.

- [ ] **Step 4: Measure the currently-deployed sidecar's memory limit (to preserve behavior)**

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/nas_jaxzin_ed25519 nas-ts \
  'export PATH=/usr/local/bin:$PATH; docker inspect tailscale-gitea --format "mem={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}"'
```
Record the values. `mem=0` means uncapped → in Task 3 set `tailscale_memory_limit: "0"`/override so the collection's 96m default does **not** newly OOM-cap tailscaled (an OOM-kill would re-break DNS). If the collection role rejects `"0"`, set a generous explicit cap (e.g. `"256m"`). Confirm the var name/semantics in `aci/roles/tailscale_sidecar/defaults/main.yml`.

- [ ] **Step 5: Confirm var parity for everything the bootstrap passes**

```bash
grep -nE "tailscale_(serve_enabled|serve_config_src|serve_config_dir|serve_domain|serve_proxy_port|host_ports|accept_dns|assert_tailnet_route|dns_servers|dns_watchdog_host_dir|memory_limit)" aci/roles/tailscale_sidecar/defaults/main.yml
```
Expected: all present. `tailscale_serve_ssh_*` will **not** be here (template-only, expected).

---

## Task 1: Re-vendor the collection at tag 1.6.0

**Files:** Replace `collections/ansible_collections/jaxzin/infra/**`; maybe create root `ansible.cfg`.

- [ ] **Step 1: Replace the vendored collection with the 1.6.0 tree**

```bash
cd <repo-root>
rm -rf collections/ansible_collections/jaxzin/infra
mkdir -p collections/ansible_collections/jaxzin/infra
# copy everything except VCS + the collection's own dev-only test dirs
rsync -a --exclude '.git' /tmp/aci/ collections/ansible_collections/jaxzin/infra/
```

- [ ] **Step 2: Verify the FQCN resolves against the freshly vendored copy**

```bash
ANSIBLE_COLLECTIONS_PATH=./collections ansible-doc -t role jaxzin.infra.tailscale_sidecar 2>&1 | head -3
```
Expected: role short_description prints. If it errors with "role not found", create `ansible.cfg` at repo root:
```ini
[defaults]
collections_path = ./collections
```
and re-run; expected PASS.

- [ ] **Step 3: Commit**

```bash
git add collections/ansible_collections/jaxzin/infra ansible.cfg 2>/dev/null
git commit -m "chore(collections): vendor jaxzin.infra 1.6.0 (tailscale_sidecar DNS watchdog, jaxzin.infra#7)"
```

---

## Task 2: Move the Serve template so the collection role can render it

**Files:** Create `playbooks/templates/ts-serve-gitea.json.j2` (content copied verbatim from the local role's `templates/ts-serve-gitea.json.j2`). It is deleted with the role in Task 5.

- [ ] **Step 1: Copy the template to the playbook templates dir**

```bash
cp playbooks/roles/tailscale_sidecar/templates/ts-serve-gitea.json.j2 playbooks/templates/ts-serve-gitea.json.j2
```
Rationale: Ansible's `template` lookup from a collection role searches `playbook_dir/templates/` after the role's own `templates/`. The collection role has no `ts-serve-gitea.json.j2`, so it must live in `playbooks/templates/`. The template references `tailscale_serve_ssh_enabled` / `tailscale_serve_ssh_forward_host` / `tailscale_serve_ssh_forward_port`, which are passed as `include_role` vars (Task 3) and thus in scope at render time.

- [ ] **Step 2: Verify it is a pure Jinja template with no role-relative includes**

```bash
grep -nE "include|import|lookup\('file'" playbooks/templates/ts-serve-gitea.json.j2 || echo "self-contained OK"
```
Expected: `self-contained OK` (or only variable interpolations). If it `include`s another role-relative file, copy that too.

- [ ] **Step 3: Commit**

```bash
git add playbooks/templates/ts-serve-gitea.json.j2
git commit -m "refactor(gitea-deploy): move ts-serve-gitea template to playbooks/templates for collection-role render"
```

---

## Task 3: Switch the deploy to the collection role

**Files:** Modify `playbooks/gitea-deploy.yml` (the `Deploy Tailscale sidecar for Gitea` block, currently ~lines 73-101).

- [ ] **Step 1: Replace the include_role block**

Replace the existing block with (keep the existing `tailscale_host_ports` comment block intact):

```yaml
    - name: Deploy Tailscale sidecar for Gitea
      include_role:
        name: jaxzin.infra.tailscale_sidecar
      when: tailscale_enabled | bool
      vars:
        tailscale_container_name: "{{ tailscale_gitea_container_name }}"
        tailscale_hostname: "{{ tailscale_gitea_hostname }}"
        tailscale_state_dir: "{{ tailscale_gitea_state_dir }}"
        tailscale_serve_enabled: true
        tailscale_serve_config_src: "ts-serve-gitea.json.j2"
        tailscale_serve_config_dir: "{{ tailscale_gitea_serve_config_dir }}"
        tailscale_serve_domain: "{{ gitea_domain }}"
        tailscale_serve_proxy_port: "3000"
        tailscale_accept_dns: true
        tailscale_serve_ssh_enabled: true
        tailscale_serve_ssh_forward_host: "127.0.0.1"
        tailscale_serve_ssh_forward_port: "{{ gitea_ssh_listen_port }}"
        tailscale_host_ports:
          - "127.0.0.1:{{ gitea_port }}:3000"
          - "{{ gitea_lan_host }}:{{ gitea_lan_ssh_port }}:{{ gitea_ssh_listen_port }}"
        # Gitea makes OUTBOUND tailnet calls (authentik OIDC discovery) through
        # this sidecar's netns, so a peer-less sidecar => ENETUNREACH. Preserve
        # the old local role's unconditional route assertion.
        tailscale_assert_tailnet_route: true
        # jaxzin.infra#7 DNS watchdog. Collection defaults already match the old
        # hardcoded wiring (dns_servers=[100.100.100.100], watchdog enabled,
        # probe one.one.one.one @ 100.100.100.100). Pin the script host-dir
        # under the gitea tailscale tree for tidiness.
        tailscale_dns_watchdog_host_dir: "{{ tailscale_gitea_state_dir | dirname }}/gitea-dns-watchdog"
        # Preserve today's memory behavior measured in Task 0 (avoid newly
        # OOM-capping tailscaled, which would re-break DNS). Replace <VALUE>
        # with the Task 0 result (e.g. "0" for uncapped, or the existing cap).
        tailscale_memory_limit: "<VALUE-FROM-TASK-0>"
```

- [ ] **Step 2: Lint the playbook**

```bash
uv run ansible-lint playbooks/gitea-deploy.yml 2>&1 | tail -20
```
Expected: no new errors referencing this block. Resolve any `var-naming`/`risky-file-permissions` only if newly introduced here.

- [ ] **Step 3: Commit**

```bash
git add playbooks/gitea-deploy.yml
git commit -m "feat(gitea-deploy): consume jaxzin.infra.tailscale_sidecar 1.6.0 (lands jaxzin.infra#7 DNS watchdog in prod)"
```

---

## Task 4: Repoint regression tests at the vendored collection role

The bootstrap regression-locks role behavior by reading role files by path. After the local role is deleted (Task 5), those paths must point at the vendored collection.

**Files:** Modify `tests/check_docker_tasks.py`, `tests/test-regression.yml`.

- [ ] **Step 1: Repoint the Python checks**

In `tests/check_docker_tasks.py`, the role path is currently `f"{ROLES_DIR}/tailscale_sidecar/tasks/main.yml"` (used by `check_tailscale_sidecar` / Check B at line ~284 and `TAILSCALE_SIDECAR_TASKS` at line ~42 / Check G at line ~390). Add a constant near the existing `ROLES_DIR` definition:

```python
# tailscale_sidecar now ships from the vendored jaxzin.infra collection, not
# the local roles/ dir (migrated 2026-06-17; jaxzin.infra#7).
COLLECTION_ROLES_DIR = "collections/ansible_collections/jaxzin/infra/roles"
```
Then change both `tailscale_sidecar` task paths to use it:
```python
TAILSCALE_SIDECAR_TASKS = f"{COLLECTION_ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
```
and inside `check_tailscale_sidecar`:
```python
    filepath = f"{COLLECTION_ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
```
(Adjust the exact constant names to match the file; `ROLES_DIR` stays for the other roles.)

- [ ] **Step 2: Run the Python checks to verify they still pass against the collection role**

```bash
uv run python tests/check_docker_tasks.py
```
Expected: exit 0. Check B (TS_ACCEPT_DNS present) and Check G (auth-key fail-fast / route assert present) must still pass — v1.6.0 has both. If Check G's matched wording differs in the collection role, update the substring it greps to match the collection's fail-fast message (keep the *intent*: assert the role fails fast on a dead `TS_AUTHKEY`).

- [ ] **Step 3: Repoint the YAML regression checks**

In `tests/test-regression.yml`:
- The serve-template read at line ~133 (`src: "{{ roles_dir }}/tailscale_sidecar/templates/ts-serve-gitea.json.j2"`) → point at the new template location `playbooks/templates/ts-serve-gitea.json.j2` (define/use a `playbook_templates_dir` var or inline the path).
- CHECK 6 (lines ~171-184) reads `{{ roles_dir }}/tailscale_sidecar/tasks/main.yml` and asserts `TS_SOCKS5_SERVER` / `:1055` → change the path to `collections/ansible_collections/jaxzin/infra/roles/tailscale_sidecar/tasks/main.yml`. v1.6.0 retains userspace gating, so the assertions hold.

- [ ] **Step 4: Add a regression-lock for the #7 watchdog presence**

Append a new CHECK to `tests/test-regression.yml` that fails if the vendored role loses the watchdog (so a future careless re-vendor can't silently drop the prod-critical fix):

```yaml
    # CHECK N: the vendored tailscale_sidecar must keep the jaxzin.infra#7 DNS
    # watchdog (upstream accept-dns bounce), else a sidecar restart re-breaks
    # Gitea OIDC. Regression-lock its presence in the vendored collection.
    - name: "CHECK N: Read vendored dns-watchdog.sh"
      ansible.builtin.slurp:
        src: "collections/ansible_collections/jaxzin/infra/roles/tailscale_sidecar/files/dns-watchdog.sh"
      register: dns_watchdog_raw

    - name: "CHECK N: dns-watchdog re-applies upstream resolvers via accept-dns bounce"
      ansible.builtin.assert:
        that:
          - "'accept-dns=false' in (dns_watchdog_raw.content | b64decode)"
          - "'accept-dns=true' in (dns_watchdog_raw.content | b64decode)"
        fail_msg: "Vendored tailscale_sidecar lost the jaxzin.infra#7 DNS upstream watchdog."
        success_msg: "jaxzin.infra#7 DNS watchdog present in vendored role."
```
(Use the next sequential CHECK number.)

- [ ] **Step 5: Commit**

```bash
git add tests/check_docker_tasks.py tests/test-regression.yml
git commit -m "test: repoint tailscale_sidecar regression checks at vendored collection + lock #7 watchdog"
```

---

## Task 5: Delete the divergent local role

**Files:** Delete `playbooks/roles/tailscale_sidecar/`.

- [ ] **Step 1: Confirm nothing else references the local role by path**

```bash
grep -rnE "roles/tailscale_sidecar|name: tailscale_sidecar\b" playbooks tests --include='*.yml' --include='*.py' \
  | grep -v "collections/ansible_collections" \
  | grep -v "jaxzin.infra.tailscale_sidecar"
```
Expected: no output. If any remain, fix them before deleting.

- [ ] **Step 2: Delete the role**

```bash
git rm -r playbooks/roles/tailscale_sidecar
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: drop local tailscale_sidecar role; bootstrap now consumes jaxzin.infra.tailscale_sidecar"
```

---

## Task 6: Offline verification (the bootstrap's own gate)

- [ ] **Step 1: Run the full offline suite**

```bash
make test
```
Expected: the regression play completes `failed=0` (baseline was `ok=49 failed=0`; counts shift with the repointed/added checks). All `check_docker_tasks.py` checks pass. If `make test` shells `ansible-playbook` without `./collections` on the path and the FQCN fails to resolve, ensure the root `ansible.cfg` from Task 1 exists (or the test harness exports `ANSIBLE_COLLECTIONS_PATH=./collections`).

- [ ] **Step 2: Syntax-check the deploy playbook with the collection resolvable**

```bash
ANSIBLE_COLLECTIONS_PATH=./collections ansible-playbook --syntax-check playbooks/gitea-deploy.yml
```
Expected: no errors; `jaxzin.infra.tailscale_sidecar` resolves.

- [ ] **Step 3: Commit any fixups, then push the branch and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "Consume jaxzin.infra.tailscale_sidecar 1.6.0 (land #7 DNS watchdog in prod, kill role drift)" \
  --body "Migrates the Gitea Tailscale sidecar off the divergent local role onto vendored jaxzin.infra 1.6.0, landing the jaxzin.infra#7 upstream-DNS watchdog in production and removing the two-copy drift. Offline suite green."
```

---

## Task 7: Deploy and verify the durable fix on the NAS

This is the real proof: the watchdog must survive a sidecar restart (the failure mode that started this).

- [ ] **Step 1: Deploy** (operator runs the normal path — `make deploy` / merge to trigger the deploy workflow). One step at a time; confirm green before proceeding.

- [ ] **Step 2: Confirm the watchdog is wired into the running container**

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/nas_jaxzin_ed25519 nas-ts 'export PATH=/usr/local/bin:$PATH
docker inspect tailscale-gitea --format "Health={{.State.Health.Status}}"
docker inspect tailscale-gitea --format "{{json .Config.Healthcheck.Test}}" | grep -o "dns-watchdog" && echo "WATCHDOG WIRED"'
```
Expected: `Health=healthy`, `WATCHDOG WIRED`.

- [ ] **Step 3: Restart the sidecar + gitea and confirm OIDC self-heals (no manual bounce)**

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/nas_jaxzin_ed25519 nas-ts 'export PATH=/usr/local/bin:$PATH
docker restart tailscale-gitea && sleep 5 && docker restart gitea && sleep 30
docker exec gitea sh -c "nslookup auth.<tailnet> 2>&1 | grep -i address | tail -1"'
curl -sS -o /dev/null -w "oidc http=%{http_code}\n" --max-time 25 https://gitea.<tailnet>/user/oauth2/authentik
```
Expected: `auth.<tailnet>` resolves to authentik's tailnet IP **without** a manual `accept-dns` bounce (the watchdog healthcheck repairs it within one interval), and the OIDC entrypoint returns **307** (redirect to authentik), not 500. Replace `<tailnet>` with the real tailnet at runtime; do not commit it.

- [ ] **Step 4: Update memory** — mark the durable fix DEPLOYED in `project_gitea_oidc_500_dns_servfail.md` (recovery is no longer "OPEN"); note prod now self-heals across restarts via the vendored collection watchdog.

---

## Self-Review notes

- **Spec coverage:** watchdog→prod (Tasks 1,3,7); drift eliminated (Task 5); DR-self-contained (Task 1 vendoring); regression locks preserved + #7 locked (Task 4); template render path (Task 2); offline gate (Task 6).
- **Open verifications deliberately deferred to Task 0** (not placeholders — they gate the irreversible edits): exact memory-limit value, `collections_path` resolution, presence of `dns-watchdog.sh` in 1.6.0, `tailscale_enabled` gating location.
- **Risk:** imposing the collection's 96m memory default where the deployed sidecar is uncapped could OOM-kill tailscaled and re-break DNS — explicitly neutralized in Task 0 Step 4 + Task 3 `tailscale_memory_limit`.
