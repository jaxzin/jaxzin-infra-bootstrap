# Gitea OIDC Source Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task. Steps use `- [ ]` checkboxes.

**Goal:** Make Gitea's `authentik` OAuth2 login source (which governs jaxzin's site-admin + fallen-leaf/Owners) self-heal from config drift, so the 2026-05-18 silent breakage (the "Claim name providing group names" field blanked, no reconciler) cannot recur.

**Architecture:** Separation of concerns across the two repos. `fallen-leaf/jaxzin-auth` owns the *what* — a hardened, idempotent, fail-closed `configure-gitea-oauth2.sh` that fully defines the source. Two triggers invoke that same script: (1) every `jaxzin-auth` deploy (CI), and (2) shortly after every Gitea container restart (the bootstrap repo provides the *when*). The restart trigger is best-effort and must never block Gitea boot (Gitea is tier-1/DR-first).

**Tech Stack:** Bash, `gitea admin auth update-oauth`/`add-oauth` CLI, Gitea Actions (`.gitea/workflows/ci.yml`), Ansible (jaxzin-infra-bootstrap `gitea_*` roles), OpenBao.

---

## File Structure

**Repo `fallen-leaf/jaxzin-auth` (Part A — deploy trigger + the reconcile logic):**
- Modify: `scripts/configure-gitea-oauth2.sh` — fail-closed when Gitea not running; own all drift-prone fields (add `--required-claim-name/value`, keep `--group-claim-name`).
- Modify: `.gitea/workflows/ci.yml` `configure` job — add SSH-to-NAS + a step that runs the hardened script (turns it from advisory into a reconciler on every deploy).
- Modify: `playbooks/roles/gitea_configure/tasks/main.yml` — install the script to a stable NAS path (`{{ gitea_data_path }}/scripts/reconcile-gitea-oauth2.sh`, root 0700) so the bootstrap restart trigger can call the same artifact.

**Repo `jaxzin-infra-bootstrap` (Part B — restart trigger):**
- Modify: `playbooks/roles/gitea_backup/templates/gitea_dump.sh.j2` — after the post-dump `docker start`, best-effort invoke the on-NAS reconcile script (covers the weekly-backup restart, the known real trigger).
- Modify: `playbooks/gitea-deploy.yml` — after the Gitea container is healthy, best-effort invoke the same script (covers stack redeploys).
- Modify: `tests/test-regression.yml` — assert both call sites invoke the reconcile script with `|| true` (non-blocking).

---

## ⚠️ BLOCKING DESIGN DECISION (Part B only)

The on-restart reconcile must read the Gitea OIDC client creds from OpenBao, so it needs an **OpenBao credential available on the NAS at Gitea-restart time, DR-safe** (Gitea boots before OpenBao in DR, so this must degrade gracefully). This is a genuine gap, not an implementation detail. Options:

1. **NAS-resident OpenBao AppRole secret-id** (file, root 0600, like `b2_credentials.env`). Restart reconcile uses it; if OpenBao unreachable → log + skip (DR-safe). *Recommended* — mirrors the existing `gitea_backup` secret pattern; least new surface.
2. **Cache the rendered OIDC client creds on the NAS** at jaxzin-auth deploy time; restart reconcile reads the cached file, no OpenBao call. Simpler at restart, but a second copy of a secret at rest.
3. **Restart trigger only verifies + alerts** (no creds needed to *read* the source via `gitea admin auth list`… but that CLI can't show the group-claim field, so verify-only can't detect this exact drift). Weakest; likely insufficient.

**Part A has no such gap** (CI already holds an OpenBao AppRole) and is unblocked. Recommendation: build Part A now; decide option 1/2 for Part B, then build it.

---

## Part A — jaxzin-auth (UNBLOCKED)

### Task A1: Harden `configure-gitea-oauth2.sh` — fail closed

**Files:** Modify `scripts/configure-gitea-oauth2.sh` (the "Check if auth source already exists" block).

- [ ] **Step 1:** Replace the existing source-detection block:

```bash
# --- Check if auth source already exists ---
step "Checking existing authentication sources"

# Fail closed: if Gitea isn't running/ready, refuse — never fall through to
# `add-oauth`, which would create a DUPLICATE source (root-cause class of the
# 2026-05-18 break + the backup-window collision risk).
if ! docker inspect -f '{{.State.Running}}' "$GITEA_CONTAINER" 2>/dev/null | grep -q true; then
  error "Gitea container '$GITEA_CONTAINER' is not running — refusing to reconcile."
  error "(Prevents creating a duplicate auth source while Gitea is mid-backup/restart.)"
  exit 1
fi

if ! EXISTING_SOURCES=$(docker exec "$GITEA_CONTAINER" gitea admin auth list 2>/dev/null); then
  error "'gitea admin auth list' failed — Gitea not ready. Aborting with no changes."
  exit 1
fi

if echo "$EXISTING_SOURCES" | grep -q "$SOURCE_NAME"; then
  SOURCE_ID=$(echo "$EXISTING_SOURCES" | grep "$SOURCE_NAME" | awk '{print $1}')
  info "Auth source '$SOURCE_NAME' already exists (ID: $SOURCE_ID)"
  ACTION="update"
else
  info "Auth source '$SOURCE_NAME' does not exist — will create"
  ACTION="create"
fi
```

- [ ] **Step 2:** Commit: `git commit -am "fix(gitea-oauth2): fail closed when Gitea not running (no duplicate source)"`

### Task A2: Own all drift-prone fields

**Files:** Modify `scripts/configure-gitea-oauth2.sh` (`COMMON_ARGS`).

- [ ] **Step 1:** Add to `COMMON_ARGS` (it already has `--group-claim-name "groups"`, `--admin-group "homelab-admins"`, `--group-team-map`, `--group-team-map-removal`):

```bash
  --required-claim-name "groups"
  --required-claim-value "homelab-users"
```

Rationale: the live source had a Required Claim set that the script did NOT manage → UI/drift could diverge it. Making the script authoritative for it means any out-of-band edit is reverted on the next reconcile. (`gitea admin auth add-oauth`/`update-oauth` both accept these flags.)

- [ ] **Step 2:** Commit: `git commit -am "fix(gitea-oauth2): script owns required-claim so the source is fully IaC-defined"`

### Task A3: CI runs the reconciler every deploy

**Files:** Modify `.gitea/workflows/ci.yml`, `configure` job (after "Run Authentik configuration playbook", ~line 459).

- [ ] **Step 1:** Add SSH key setup to the `configure` job steps (mirror the `deploy` job's "Write SSH key"):

```yaml
      - name: Write SSH key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.DEPLOY_SSH_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H nas >> ~/.ssh/known_hosts 2>/dev/null
```

- [ ] **Step 2:** Add a reconcile step at the end of the `configure` job:

```yaml
      - name: Reconcile Gitea OAuth2 source (self-heal drift)
        env:
          TS_TAILNET: ${{ secrets.TS_TAILNET }}
          BAO_TOKEN: ${{ steps.bao_auth.outputs.VAULT_TOKEN }}
          DEPLOY_SSH_USER: ${{ secrets.DEPLOY_SSH_USER }}
        run: |
          ssh -i ~/.ssh/id_ed25519 "${DEPLOY_SSH_USER}@nas" \
            "TS_TAILNET='${TS_TAILNET}' BAO_ADDR='${OPENBAO_ADDR}' BAO_TOKEN='${BAO_TOKEN}' bash -s" \
            < scripts/configure-gitea-oauth2.sh
```

- [ ] **Step 3:** Commit: `git commit -am "feat(ci): reconcile Gitea OAuth2 source on every deploy (was advisory only)"`

### Task A4: Install the script to a stable NAS path (seam for Part B)

**Files:** Modify `playbooks/roles/gitea_configure/tasks/main.yml`.

- [ ] **Step 1:** Add a task (runs only when Gitea is reachable, which the role already checks):

```yaml
- name: Install OAuth2 reconcile script to a stable NAS path (for the on-restart self-heal)
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/../scripts/configure-gitea-oauth2.sh"
    dest: "{{ gitea_data_path }}/scripts/reconcile-gitea-oauth2.sh"
    owner: root
    group: root
    mode: '0700'
  become: true
  when: gitea_configure_health is succeeded
```

- [ ] **Step 2:** Commit: `git commit -am "feat(gitea_configure): install reconcile script to NAS for restart self-heal"`

---

## Part B — jaxzin-infra-bootstrap (AFTER design decision above)

### Task B1: Regression test first (TDD)

**Files:** Modify `tests/test-regression.yml` (new CHECK before Cleanup).

- [ ] **Step 1:** Add:

```yaml
    - name: "CHECK 12: gitea backup + deploy invoke the OIDC reconcile, non-blocking"
      vars:
        dump_tpl: "{{ lookup('file', roles_dir + '/gitea_backup/templates/gitea_dump.sh.j2') }}"
        deploy_yml: "{{ lookup('file', project_root + '/playbooks/gitea-deploy.yml') }}"
      assert:
        that:
          - "'reconcile-gitea-oauth2.sh' in dump_tpl"
          - "'reconcile-gitea-oauth2.sh' in deploy_yml"
          - "'|| true' in dump_tpl"
        fail_msg: >
          The Gitea OIDC source self-heal must run after the post-dump restart
          and after a stack deploy, and must be non-blocking (|| true) so it
          never prevents Gitea (tier-1/DR-first) from coming up.
```

- [ ] **Step 2:** Run `make test`; expect CHECK 12 FAIL (`reconcile-gitea-oauth2.sh` not present yet).

### Task B2: Backup post-restart self-heal

**Files:** Modify `playbooks/roles/gitea_backup/templates/gitea_dump.sh.j2` (in `cleanup()` / after the post-dump `docker start`, around the `# (#110)` restart marker).

- [ ] **Step 1:** After the line that restarts Gitea post-dump, add:

```bash
# (#oidc) Best-effort self-heal of the OIDC source after the restart.
# Never blocks: Gitea is tier-1/DR-first; a reconcile failure must not matter.
if [ -x "$HOST_DATA_DIR/scripts/reconcile-gitea-oauth2.sh" ]; then
  echo "INFO: reconciling Gitea OAuth2 source post-restart (best-effort)..."
  "$HOST_DATA_DIR/scripts/reconcile-gitea-oauth2.sh" || true
fi
```

- [ ] **Step 2:** `make test`; expect CHECK 12 still fails on `deploy_yml` assertion.

### Task B3: Deploy post-health self-heal

**Files:** Modify `playbooks/gitea-deploy.yml` (after the existing "wait for Gitea ready" task in Play 1).

- [ ] **Step 1:** Add:

```yaml
    - name: Self-heal the Gitea OAuth2 source after deploy (best-effort)
      ansible.builtin.command:
        cmd: "{{ gitea_data_path }}/scripts/reconcile-gitea-oauth2.sh"
      become: true
      failed_when: false   # tier-1/DR-first: never fail the deploy on reconcile
      changed_when: false
```

- [ ] **Step 2:** `make test`; expect CHECK 12 PASS.
- [ ] **Step 3:** Commit: `git commit -am "feat(gitea): self-heal OIDC source on restart + deploy (non-blocking) (#oidc)"`

---

## Self-Review

- **Spec coverage:** deploy trigger = Task A3; restart trigger = Tasks B2/B3; fail-closed = A1; own-all-fields = A2; regression-lock = B1; DR-safe (non-blocking) = B2/B3 `|| true`/`failed_when:false` + CHECK 12. Covered.
- **Open item:** Part B secret-access design decision (option 1/2/3) — explicitly surfaced, not a placeholder.
- **Cross-repo seam:** A4 installs `reconcile-gitea-oauth2.sh` to `{{ gitea_data_path }}/scripts/`; B2/B3 call that exact path. Consistent.
