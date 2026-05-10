# Gitea Deploy-Key Stub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Acknowledge the manually-added Home Assistant deploy key on the homelab Gitea, confirm there's no Gitea-API-driven IaC pattern in this repo to port it into, and open a tracking issue for "manage Gitea deploy keys via the API once there are 2+ to manage." Per issue #5's explicit guidance: **do not invent a pattern for one key**.

**Architecture:** This is a paperwork plan — no code, no roles, no workflows. The deliverable is (a) a tracking issue on the homelab Gitea and (b) a short note in the gitea_server role's docs so a future bootstrap-from-zero operator knows the manually-added key exists and where to recreate it.

**Tech Stack:** Gitea (issues), markdown.

**Tracking:** Issue #5 deliverable #3.

---

### Task 1: Confirm there's no existing Gitea-API IaC pattern in this repo

**Files:** none (read-only audit)

This is a precondition check — issue #5 says "If `jaxzin-infra-bootstrap` already has a Gitea-API-driven pattern for deploy keys / webhooks / repo state, port this manual addition into it." We need to confirm no such pattern exists before defaulting to the "open a tracking issue" path.

- [ ] **Step 1: Search for Gitea-API usage in playbooks and roles**

```bash
grep -rn 'gitea.*api\|/api/v1\|gitea_api\|/repos/' \
  playbooks/ \
  --include='*.yml' --include='*.yaml' --include='*.j2'
```

Expected: matches confined to internal-token / health-check API calls (gitea_internal_token, /api/v1/version, etc.) — nothing that creates/lists deploy keys, webhooks, or repository content.

- [ ] **Step 2: Search for the Gitea Ansible collection or community modules**

```bash
grep -rn 'gitea_repo\|gitea_user\|gitea_team\|gitea_deploy_key' \
  playbooks/ collections/ requirements.yml playbooks/galaxy-requirements.yml \
  2>/dev/null
```

Expected: zero matches.

- [ ] **Step 3: Search for any URI-module calls against the Gitea API**

```bash
grep -rn 'community.*\.uri\|ansible.builtin.uri' playbooks/ \
  --include='*.yml' --include='*.yaml' \
  | grep -i gitea || echo 'no Gitea API calls via uri found'
```

Expected: prints `no Gitea API calls via uri found`.

- [ ] **Step 4: Document the finding inline**

If steps 1–3 all confirm no existing pattern, proceed to Task 2. If an existing pattern *is* found (unlikely), STOP and switch strategies — port the manual addition into the existing pattern rather than opening a tracking issue. That alternate path is not detailed here because it's unlikely.

---

### Task 2: Open the Gitea tracking issue

**Files:** none (issue created via Gitea API / UI)

- [ ] **Step 1: Draft the issue body**

Title: `Track Gitea repo-state IaC (deploy keys, webhooks, mirror config) when there are 2+ to manage`

Body:

```markdown
## Context

We currently have one manually-managed Gitea repo-state artifact:

- A deploy key with **write access** on `fallen-leaf/home-assistant`, title `homeassistant-config-deploy`, used by the HA host's `/config` git workflow. (Public key is safe to share; the corresponding private key lives at `/config/.ssh/gitea_id_ed25519` on the HA host.)

Surfaced during issue #5 deliverable #3.

Per #5: "If `jaxzin-infra-bootstrap` already has a Gitea-API-driven pattern for deploy keys / webhooks / repo state, port this manual addition into it. If not, **don't invent a pattern for one key**." Audit confirmed there's no existing pattern, so we're tracking this for later instead of inventing one now.

## Trigger to act on this issue

Open this issue when **any** of the following becomes true:

- A second deploy key needs managing (any repo).
- A webhook needs managing as code.
- A push-mirror config needs managing as code (the existing one to github.com counts when we want it declarative; currently it's manually configured per the README's "What You Need to Do Once" section).
- A Gitea user/team/org needs creating as code.

At that point, the right design is probably either:
- An Ansible role using the `community.general.gitea` modules (or raw `uri:` calls against `/api/v1/...` with the existing `gitea_internal_token` / an admin token), OR
- An OpenTofu module using the `go-gitea/gitea` provider (if it has matured).

The decision should be made when we know the second use case, since that determines which abstraction shape fits.

## Until then

The HA deploy key remains manually added via the Gitea UI. A note in `playbooks/roles/gitea_server/` documents its existence for future bootstrap-from-zero operators (issue #5 plan #3 task 3).

## Out of scope

- Managing repo creation (forks/migrations) as code — separate concern.
- Managing repo settings (branch protection, etc.) as code — separate concern.
```

- [ ] **Step 2: Create the issue on the homelab Gitea**

Either via the Gitea UI (Issues → New) or via `mcp__gitea__issue_write` if MCP tools are available. Owner: `jaxzin`, Repo: `jaxzin-infra-bootstrap`. Title and body from step 1.

The issue stays on Gitea (per #5's hard rule that #5's contents stay on Gitea). Keeping this tracking issue colocated with #5 keeps the audit trail in one place.

- [ ] **Step 3: Note the new issue number**

Capture the new issue's number (e.g., `#7`) — it gets referenced in the README note in Task 3.

---

### Task 3: Add a one-paragraph note in `playbooks/roles/gitea_server/`

**Files:**
- Create OR Modify: `playbooks/roles/gitea_server/README.md`

This note serves the bootstrap-from-zero operator: after a full DR, when Gitea is back up, what manually-managed bits aren't yet captured as code? Currently: this one deploy key.

- [ ] **Step 1: Check whether the role already has a README**

```bash
ls playbooks/roles/gitea_server/README.md 2>&1 || echo 'absent'
```

If absent, create a fresh README with a brief role description and the new "Manually-managed state" section. If present, append the section.

- [ ] **Step 2: Write the section**

```markdown
## Manually-managed state (TODO: capture as code)

Some Gitea repository-level state on the homelab Gitea instance is currently configured manually via the UI rather than as code. After a full DR (Gitea data restored from backup), the restored state already includes these — they only need re-applying after a *zero-state* bootstrap (e.g., a fresh test environment).

| Item | Where | Notes |
|---|---|---|
| Deploy key on `fallen-leaf/home-assistant` (`homeassistant-config-deploy`) | Gitea UI → repo → Settings → Deploy Keys | Public key lives at `/config/.ssh/gitea_id_ed25519.pub` on the HA host. Tracked for IaC capture in issue #<NEW_TRACKING_ISSUE>. |

If you find yourself adding a *second* item to this table, that's the trigger to design and ship a Gitea-API-driven pattern (Ansible role or Tofu module) — see the tracking issue.
```

Replace `<NEW_TRACKING_ISSUE>` with the number captured in Task 2 step 3.

- [ ] **Step 3: Commit**

```bash
git add playbooks/roles/gitea_server/README.md
git commit -m "docs(gitea_server): note manually-managed deploy key + IaC tracking issue"
```

---

## Out of scope for this plan

- Building a Gitea-API IaC role/module. Explicitly deferred until 2+ items need managing.
- Capturing the github.com push-mirror as code. Same deferral logic; it's a single mirror configured per the README's onboarding instructions.
- Rotating the existing deploy key. The key is still in active use; rotation is a separate ops concern.
