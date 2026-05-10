# UniFi Static DNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the LAN static-DNS record for `${GITEA_LAN_FQDN} → ${GITEA_LAN_HOST}` (and any future bootstrap-related records) declaratively in OpenTofu, served by the existing UniFi Cloud Gateway's built-in static-DNS feature.

**Architecture:** New `tofu/network/` root module using the `ubiquiti-community/unifi` provider, with state stored in Backblaze B2 via the S3-compat backend. Two new CI workflows (one in `.gitea/workflows/`, one in `.github/workflows/`) run plan-on-PR and apply-on-push-to-main on the existing on-prem self-hosted runner. All inputs come from CI Secrets (never Variables) — this repo is the bootstrap-layer exception that may use CI Secrets directly; downstream repos copying this module must source credentials from OpenBao instead.

**Tech Stack:** OpenTofu (>= 1.10), `ubiquiti-community/unifi` provider (>= 0.41), Backblaze B2 S3-compat, GitHub Actions, Gitea Actions, `dig`, `jq`

**Tracking:** Issue #5 deliverable #2.

**Reference:** `docs/plans/2026-05-10-unifi-static-dns-design.md` — design doc with full rationale, alternative approaches, layering rules, and threat-model notes. Read it before starting.

**Prerequisites:**
- Issue #6 (Variables → Secrets migration) should land first to keep the all-Secrets-for-topology pattern uniform across the repo.
- Plan #1 (Gitea LAN-SSH bind) should land first so the DNS record points at a working LAN-bound SSH listener immediately on apply. Either order works in principle; this is the natural one.

---

### Task 1: Bootstrap the OpenTofu module skeleton

**Files:**
- Create: `tofu/network/versions.tf`
- Create: `tofu/network/variables.tf`
- Create: `tofu/network/providers.tf`

This task lands a *compileable* module with no resources yet. It validates that the provider downloads cleanly and the variable schema matches what we'll feed in later.

- [ ] **Step 1: Create `tofu/network/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = ">= 0.41, < 1.0"
    }
  }
}
```

The version pin ranges absorb patch fixes but stop before any 1.x major. OpenTofu 1.10 is required for S3 backend `use_lockfile` (a later task).

- [ ] **Step 2: Create `tofu/network/variables.tf`**

```hcl
variable "unifi_api_url" {
  description = "UniFi controller URL, e.g. https://<controller-host>"
  type        = string
}

variable "unifi_username" {
  description = "Local UniFi admin username for OpenTofu (dedicated user, not the operator's account)"
  type        = string
}

variable "unifi_password" {
  description = "Password for the dedicated OpenTofu UniFi user"
  type        = string
  sensitive   = true
}

variable "unifi_site" {
  description = "UniFi site identifier (typically 'default')"
  type        = string
  default     = "default"
}

variable "unifi_insecure" {
  description = "Skip TLS verification on the controller URL (rare; only for self-signed dev controllers)"
  type        = bool
  default     = false
}

variable "unifi_static_dns" {
  description = "List of static DNS records to manage on the UniFi controller."
  type = list(object({
    name  = string
    value = string
    type  = string
  }))
  default = []
  validation {
    condition     = alltrue([for r in var.unifi_static_dns : contains(["A", "AAAA", "CNAME", "TXT"], r.type)])
    error_message = "Each unifi_static_dns record's type must be A, AAAA, CNAME, or TXT."
  }
}
```

- [ ] **Step 3: Create `tofu/network/providers.tf`**

```hcl
provider "unifi" {
  api_url        = var.unifi_api_url
  username       = var.unifi_username
  password       = var.unifi_password
  site           = var.unifi_site
  allow_insecure = var.unifi_insecure
}
```

Every field references `var.*`. The provider itself never sees a hardcoded value.

- [ ] **Step 4: Verify the skeleton compiles**

```bash
cd tofu/network
tofu fmt -check
tofu init -backend=false
tofu validate
```

Expected:
- `tofu fmt -check`: no output (clean)
- `tofu init -backend=false`: provider downloads, no errors
- `tofu validate`: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add tofu/network/versions.tf tofu/network/variables.tf tofu/network/providers.tf
git commit -m "feat(tofu): scaffold tofu/network module for UniFi LAN config"
```

---

### Task 2: Add the DNS resource and a fixtures-driven local plan

**Files:**
- Create: `tofu/network/dns.tf`
- Create: `tofu/network/tests/fixtures.tfvars` (gitignored at the file level — see step 4)
- Modify: `.gitignore`

- [ ] **Step 1: Create `tofu/network/dns.tf`**

```hcl
resource "unifi_dns_record" "this" {
  for_each = { for r in var.unifi_static_dns : r.name => r }

  name   = each.value.name
  value  = each.value.value
  record = each.value.type
}
```

Map keying by `name` (rather than list indexing) keeps the resource address `unifi_dns_record.this["<name>"]` stable across list reorderings, so a swap of two list entries in `var.unifi_static_dns` doesn't trigger destroy+recreate.

- [ ] **Step 2: Create the fixtures file with synthetic-only values**

Create `tofu/network/tests/fixtures.tfvars`:

```hcl
unifi_api_url    = "https://controller.test.invalid"
unifi_username   = "fixture-user"
unifi_password   = "fixture-password-not-real"
unifi_site       = "default"
unifi_insecure   = false
unifi_static_dns = [
  {
    name  = "fixture.test.invalid"
    value = "192.0.2.1"
    type  = "A"
  },
]
```

`192.0.2.0/24` is the IETF documentation-only range (RFC 5737) — non-routable, safe in code. `.test.invalid` per RFC 2606.

- [ ] **Step 3: Add `tests/` to the module-local gitignore**

The fixtures file is safe to commit (no real values), but to prevent accidentally committing a *real* tfvars file with actual secrets later, add a guard. Edit `.gitignore` at the repo root and append:

```gitignore
# OpenTofu local state and any non-fixture tfvars
tofu/**/*.tfstate
tofu/**/*.tfstate.backup
tofu/**/.terraform/
tofu/**/.terraform.lock.hcl
tofu/**/*.tfvars
!tofu/**/tests/fixtures.tfvars
```

The negation rule `!tofu/**/tests/fixtures.tfvars` is essential — it re-allows the synthetic-only file we *do* want committed. Without that, future tests/fixtures contributions would silently be ignored.

- [ ] **Step 4: Run a fixtures-only validate + plan**

```bash
cd tofu/network
tofu init -backend=false
tofu validate
tofu plan -refresh=false -var-file=tests/fixtures.tfvars
```

Expected: `tofu plan` output mentions creating `unifi_dns_record.this["fixture.test.invalid"]`. The plan WILL likely fail at the network layer (controller URL is `.invalid`, will not resolve), but it will fail *after* schema validation — which is what we want. If it fails at schema validation, fix the schema; if it fails at network, ignore (this is a local-only check).

To run a clean schema-only check that doesn't try to reach the controller:

```bash
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add tofu/network/dns.tf tofu/network/tests/fixtures.tfvars .gitignore
git commit -m "feat(tofu): unifi_dns_record resource + fixtures for local validate"
```

---

### Task 3: Add the B2 S3-compat backend configuration

**Files:**
- Create: `tofu/network/backend.tf`

- [ ] **Step 1: Create `tofu/network/backend.tf`**

```hcl
terraform {
  backend "s3" {
    # All concrete settings are supplied via `tofu init -backend-config=...`
    # at run time so no topology lives in this file.
    #
    # Required at init:
    #   endpoint                   - B2 S3-compat endpoint URL
    #   bucket                     - state bucket name
    #   key                        - "tofu-state/jaxzin-infra-bootstrap/network.tfstate"
    #   region                     - any value B2 accepts; "us-west-002" is typical
    #   skip_credentials_validation - true (B2 doesn't implement STS)
    #   skip_metadata_api_check     - true (no EC2 metadata)
    #   skip_region_validation      - true (B2 region naming differs from AWS)
    #   skip_requesting_account_id  - true (B2 doesn't expose AWS account IDs)
    #   use_lockfile                - true (S3 conditional-write locks)
    #   force_path_style            - true (B2 requires path-style addressing)
  }
}
```

The empty `backend "s3" {}` block declares intent; concrete config is supplied at `init` time. This is the pattern that keeps topology out of the committed file.

- [ ] **Step 2: Verify init still works in skeleton mode**

The repository contributors will not run `init` against B2 from their workstations — only CI does. But the syntax should still be valid. Confirm:

```bash
cd tofu/network
tofu init -backend=false
tofu validate
```

Expected: still `Success! The configuration is valid.` (the backend block is recognized but unused when `-backend=false`).

- [ ] **Step 3: Commit**

```bash
git add tofu/network/backend.tf
git commit -m "feat(tofu): declare B2 S3-compat backend (config supplied at init time)"
```

---

### Task 4: Write the module README documenting inputs, layering, and one-time setup

**Files:**
- Create: `tofu/network/README.md`

- [ ] **Step 1: Write the README**

Create `tofu/network/README.md` with this content. The README is the single source of truth for "how do I use this module" and explicitly calls out the bootstrap-layer exception so future copy-paste consumers don't inherit the wrong pattern.

```markdown
# tofu/network

OpenTofu root module that manages this repo's slice of LAN-side static DNS on the UniFi Cloud Gateway. Designed to be **copy-able into other service repos** that need to manage their own slices of `*.${LAN_DOMAIN}` records.

## What it does

Manages a list of static DNS records on the UniFi controller via `unifi_dns_record`. Each record is an entry in `var.unifi_static_dns`:

```hcl
unifi_static_dns = [
  {
    name  = "<fqdn>"
    value = "<lan-ip>"
    type  = "A"
  },
]
```

State is stored in Backblaze B2 via the S3-compat backend; locking uses S3 conditional writes (no DynamoDB needed).

## Inputs

| Variable | Type | Required | Description |
|---|---|---|---|
| `unifi_api_url` | string | yes | Controller URL |
| `unifi_username` | string | yes | Dedicated UniFi local admin username |
| `unifi_password` | string | yes (sensitive) | Password for that user |
| `unifi_site` | string | no (default `"default"`) | UniFi site ID |
| `unifi_insecure` | bool | no (default `false`) | Skip TLS verification |
| `unifi_static_dns` | list(object) | no (default `[]`) | Records to manage |

## One-time operator setup (this repo)

These steps cannot be code (they bootstrap the credentials code uses).

1. **Create the dedicated UniFi local user:** in the controller UI → Settings → Admins → Add Admin. Username: `tofu` (or similar). Role: Super Admin (or scoped if your firmware version supports a tighter role). Restrict to local access. Save the password.
2. **Create the new CI Secrets** (in BOTH the GitHub repo AND the homelab Gitea repo):
   - `UNIFI_API_URL` — controller URL
   - `UNIFI_USERNAME` — the user from step 1
   - `UNIFI_PASSWORD` — that user's password
   - `UNIFI_SITE` — typically `default`
   - `B2_S3_ENDPOINT` — B2 S3-compat endpoint URL (e.g., `https://s3.us-west-002.backblazeb2.com`)
   - `TOFU_STATE_BUCKET` — bucket name (set to the same value as `B2_BUCKET_NAME` initially)
   - `TOFU_STATE_KEY` — `tofu-state/jaxzin-infra-bootstrap/network.tfstate`
   - `GITEA_LAN_HOST` — the LAN IP for the Gitea record (already set up in plan #1)
   - `GITEA_LAN_FQDN` — the LAN FQDN for the Gitea record
3. **Verify the bucket prefix exists:** the B2 S3-compat backend will create the key on first `init`, but confirm the bucket exists and the credentials have write access.

## ⚠️ Layering rule — bootstrap-layer exception

`jaxzin-infra-bootstrap` is the bootstrap layer of the IaC stack. It is the **only repo** in this stack permitted to source credentials directly from CI Secrets. OpenBao is the second thing deployed during disaster recovery; if any repo whose workflow runs *during* the bootstrap chain depended on OpenBao for its secrets, DR would have a circular dependency.

If you copy this module into another repo:

- Copy `versions.tf`, `providers.tf`, `dns.tf`, `variables.tf`, `backend.tf` verbatim.
- Change the state `key` so the new repo gets its own state file.
- **Replace the CI workflow's secret-injection step** with one that fetches credentials from OpenBao (e.g., the Vault provider's `vault_generic_secret`, or a pre-`tofu init` shim that exports `TF_VAR_*`).

The module body is portable. The "credentials live in CI Secrets" pattern in *this* repo's workflows is the exception, not the template.

## Failure modes

| Failure | Symptom | Response |
|---|---|---|
| Controller unreachable | `plan`/`apply` HTTP timeout | Workflow fails. State unchanged. Retry when controller returns. |
| Bad credentials | Provider 401 | Rotate `UNIFI_PASSWORD`. |
| State backend unreachable | `init` fails | Workflow fails. Wait for B2 or restore. |
| State drift (manual UI edit) | `plan` shows unexpected diff | PR review catches it. Decide: import or revert. |

## Related

- Design: `docs/plans/2026-05-10-unifi-static-dns-design.md`
- Plan: `docs/plans/2026-05-10-unifi-static-dns-plan.md`
- Tracking issue: #5 deliverable #2
```

- [ ] **Step 2: Commit**

```bash
git add tofu/network/README.md
git commit -m "docs(tofu): module README with inputs, setup, and layering caveat"
```

---

### Task 5: Create the Gitea Actions workflow

**Files:**
- Create: `.gitea/workflows/network.yml`

- [ ] **Step 1: Read an existing Gitea workflow for shape reference**

```bash
cat .gitea/workflows/deploy.yml
```

Note the `runs-on:` value, the `container:` image (if any), and how Secrets are referenced. Match those conventions in the new file.

- [ ] **Step 2: Create the workflow**

```yaml
# .gitea/workflows/network.yml
name: Network IaC

on:
  push:
    branches: [main]
    paths:
      - "tofu/network/**"
      - ".gitea/workflows/network.yml"
  pull_request:
    paths:
      - "tofu/network/**"
      - ".gitea/workflows/network.yml"

jobs:
  network:
    runs-on: [self-hosted, linux]
    env:
      # OpenTofu reads TF_VAR_* into module variables.
      TF_VAR_unifi_api_url:    ${{ secrets.UNIFI_API_URL }}
      TF_VAR_unifi_username:   ${{ secrets.UNIFI_USERNAME }}
      TF_VAR_unifi_password:   ${{ secrets.UNIFI_PASSWORD }}
      TF_VAR_unifi_site:       ${{ secrets.UNIFI_SITE }}
      # The DNS list is built inline from individual Secrets so this repo's
      # records stay parameterized via the same env-var pattern as everything
      # else. Add to TF_VAR_unifi_static_dns if more records land in this repo.
      TF_VAR_unifi_static_dns: |
        [
          {
            "name":  "${{ secrets.GITEA_LAN_FQDN }}",
            "value": "${{ secrets.GITEA_LAN_HOST }}",
            "type":  "A"
          }
        ]
      # S3-compat backend creds (B2)
      AWS_ACCESS_KEY_ID:     ${{ secrets.B2_APPLICATION_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.B2_APPLICATION_KEY }}
      # Backend config values
      B2_S3_ENDPOINT:        ${{ secrets.B2_S3_ENDPOINT }}
      TOFU_STATE_BUCKET:     ${{ secrets.TOFU_STATE_BUCKET }}
      TOFU_STATE_KEY:        ${{ secrets.TOFU_STATE_KEY }}
      # For dig verification step
      LAN_DNS:               ${{ secrets.LAN_DNS }}
      GITEA_LAN_FQDN:        ${{ secrets.GITEA_LAN_FQDN }}
      GITEA_LAN_HOST:        ${{ secrets.GITEA_LAN_HOST }}
      # For Discord notification on failure
      DISCORD_WEBHOOK:       ${{ secrets.DISCORD_WEBHOOK }}

    defaults:
      run:
        working-directory: tofu/network

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install OpenTofu
        uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: "1.10.0"

      - name: tofu fmt
        run: tofu fmt -check -recursive

      - name: tofu init
        run: |
          tofu init \
            -backend-config="endpoint=${B2_S3_ENDPOINT}" \
            -backend-config="bucket=${TOFU_STATE_BUCKET}" \
            -backend-config="key=${TOFU_STATE_KEY}" \
            -backend-config="region=us-west-002" \
            -backend-config="skip_credentials_validation=true" \
            -backend-config="skip_metadata_api_check=true" \
            -backend-config="skip_region_validation=true" \
            -backend-config="skip_requesting_account_id=true" \
            -backend-config="use_lockfile=true" \
            -backend-config="force_path_style=true"

      - name: tofu validate
        run: tofu validate

      - name: tofu plan
        run: tofu plan -out=plan.out -input=false

      - name: Plan summary (counts only — never the diff body)
        run: |
          tofu show -json plan.out > plan.json
          add=$(jq '[.resource_changes[] | select(.change.actions | index("create"))] | length' plan.json)
          chg=$(jq '[.resource_changes[] | select(.change.actions | index("update"))] | length' plan.json)
          del=$(jq '[.resource_changes[] | select(.change.actions | index("delete"))] | length' plan.json)
          echo "Plan: ${add} to add, ${chg} to change, ${del} to destroy."

      - name: tofu apply
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: tofu apply -input=false -auto-approve plan.out

      - name: Verify DNS resolution after apply
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          # Allow the controller a moment to propagate to dnsmasq.
          for i in 1 2 3 4 5 6; do
            result=$(dig +short "${GITEA_LAN_FQDN}" @"${LAN_DNS}")
            if [ "${result}" = "${GITEA_LAN_HOST}" ]; then
              echo "dig verification OK"
              exit 0
            fi
            echo "attempt ${i}: got '${result}', expected '${GITEA_LAN_HOST}'; sleeping 5s"
            sleep 5
          done
          echo "ERROR: DNS did not propagate to expected value within 30s"
          exit 1
```

The "Plan summary" step uses `jq` on the JSON form of the plan; this is the only safe way to surface plan results on the public mirror. The diff body is never echoed.

- [ ] **Step 3: Lint the workflow**

```bash
# If actionlint is installed locally; otherwise rely on Gitea/GitHub to surface errors at runtime.
actionlint .gitea/workflows/network.yml || true
```

Expected: no errors. If `actionlint` is not installed, skip.

- [ ] **Step 4: Commit**

```bash
git add .gitea/workflows/network.yml
git commit -m "ci(gitea): network workflow for tofu plan-on-PR / apply-on-main"
```

---

### Task 6: Create the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/network.yml`

The DR scenario explicitly requires the GitHub copy to exist independently of Gitea, so a missing homelab cluster doesn't block reconciliation of network state. The two files are intentionally near-identical — the duplication is the point.

- [ ] **Step 1: Create the file with the full content**

```yaml
# .github/workflows/network.yml
name: Network IaC

on:
  push:
    branches: [main]
    paths:
      - "tofu/network/**"
      - ".github/workflows/network.yml"
  pull_request:
    paths:
      - "tofu/network/**"
      - ".github/workflows/network.yml"

jobs:
  network:
    runs-on: [self-hosted, linux]
    env:
      TF_VAR_unifi_api_url:    ${{ secrets.UNIFI_API_URL }}
      TF_VAR_unifi_username:   ${{ secrets.UNIFI_USERNAME }}
      TF_VAR_unifi_password:   ${{ secrets.UNIFI_PASSWORD }}
      TF_VAR_unifi_site:       ${{ secrets.UNIFI_SITE }}
      TF_VAR_unifi_static_dns: |
        [
          {
            "name":  "${{ secrets.GITEA_LAN_FQDN }}",
            "value": "${{ secrets.GITEA_LAN_HOST }}",
            "type":  "A"
          }
        ]
      AWS_ACCESS_KEY_ID:     ${{ secrets.B2_APPLICATION_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.B2_APPLICATION_KEY }}
      B2_S3_ENDPOINT:        ${{ secrets.B2_S3_ENDPOINT }}
      TOFU_STATE_BUCKET:     ${{ secrets.TOFU_STATE_BUCKET }}
      TOFU_STATE_KEY:        ${{ secrets.TOFU_STATE_KEY }}
      LAN_DNS:               ${{ secrets.LAN_DNS }}
      GITEA_LAN_FQDN:        ${{ secrets.GITEA_LAN_FQDN }}
      GITEA_LAN_HOST:        ${{ secrets.GITEA_LAN_HOST }}
      DISCORD_WEBHOOK:       ${{ secrets.DISCORD_WEBHOOK }}

    defaults:
      run:
        working-directory: tofu/network

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install OpenTofu
        uses: opentofu/setup-opentofu@v1
        with:
          tofu_version: "1.10.0"

      - name: tofu fmt
        run: tofu fmt -check -recursive

      - name: tofu init
        run: |
          tofu init \
            -backend-config="endpoint=${B2_S3_ENDPOINT}" \
            -backend-config="bucket=${TOFU_STATE_BUCKET}" \
            -backend-config="key=${TOFU_STATE_KEY}" \
            -backend-config="region=us-west-002" \
            -backend-config="skip_credentials_validation=true" \
            -backend-config="skip_metadata_api_check=true" \
            -backend-config="skip_region_validation=true" \
            -backend-config="skip_requesting_account_id=true" \
            -backend-config="use_lockfile=true" \
            -backend-config="force_path_style=true"

      - name: tofu validate
        run: tofu validate

      - name: tofu plan
        run: tofu plan -out=plan.out -input=false

      - name: Plan summary (counts only — never the diff body)
        run: |
          tofu show -json plan.out > plan.json
          add=$(jq '[.resource_changes[] | select(.change.actions | index("create"))] | length' plan.json)
          chg=$(jq '[.resource_changes[] | select(.change.actions | index("update"))] | length' plan.json)
          del=$(jq '[.resource_changes[] | select(.change.actions | index("delete"))] | length' plan.json)
          echo "Plan: ${add} to add, ${chg} to change, ${del} to destroy."

      - name: tofu apply
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: tofu apply -input=false -auto-approve plan.out

      - name: Verify DNS resolution after apply
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          for i in 1 2 3 4 5 6; do
            result=$(dig +short "${GITEA_LAN_FQDN}" @"${LAN_DNS}")
            if [ "${result}" = "${GITEA_LAN_HOST}" ]; then
              echo "dig verification OK"
              exit 0
            fi
            echo "attempt ${i}: got '${result}', expected '${GITEA_LAN_HOST}'; sleeping 5s"
            sleep 5
          done
          echo "ERROR: DNS did not propagate to expected value within 30s"
          exit 1
```

The only structural difference from `.gitea/workflows/network.yml` is the path-trigger glob: `.github/workflows/network.yml` references itself (so it re-runs when the workflow file is edited). Same provider, same Secret names, same `runs-on:` label — both run on the same on-prem self-hosted runner pool.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/network.yml
git commit -m "ci(github): network workflow mirror for DR re-apply path"
```

---

### Task 7: Add a drift-detection job to the existing daily health check

**Files:**
- Modify: `.github/workflows/health-check.yml`

The design (§4.3) calls for a daily `tofu plan -detailed-exitcode` that surfaces drift via Discord. The simplest landing is to extend the existing `health-check.yml` so the daily-Discord pattern stays uniform.

- [ ] **Step 1: Read the existing workflow**

```bash
cat .github/workflows/health-check.yml
```

Identify the existing job structure and the Discord notification step shape.

- [ ] **Step 2: Add a `network-drift` job**

Append a new job to the same workflow file (parallel to the existing health-check job). The new job runs `tofu init` (same backend-config flags as the network workflow) and `tofu plan -detailed-exitcode -input=false`. On exit code `2` (drift detected), sends a Discord message via the existing `DISCORD_WEBHOOK` secret. Exit code `0` (no changes) is silent. Exit code `1` (error) sends a different Discord message.

```yaml
  network-drift:
    runs-on: [self-hosted, linux]
    env:
      TF_VAR_unifi_api_url:    ${{ secrets.UNIFI_API_URL }}
      TF_VAR_unifi_username:   ${{ secrets.UNIFI_USERNAME }}
      TF_VAR_unifi_password:   ${{ secrets.UNIFI_PASSWORD }}
      TF_VAR_unifi_site:       ${{ secrets.UNIFI_SITE }}
      TF_VAR_unifi_static_dns: |
        [
          {
            "name":  "${{ secrets.GITEA_LAN_FQDN }}",
            "value": "${{ secrets.GITEA_LAN_HOST }}",
            "type":  "A"
          }
        ]
      AWS_ACCESS_KEY_ID:     ${{ secrets.B2_APPLICATION_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.B2_APPLICATION_KEY }}
      B2_S3_ENDPOINT:        ${{ secrets.B2_S3_ENDPOINT }}
      TOFU_STATE_BUCKET:     ${{ secrets.TOFU_STATE_BUCKET }}
      TOFU_STATE_KEY:        ${{ secrets.TOFU_STATE_KEY }}
      DISCORD_WEBHOOK:       ${{ secrets.DISCORD_WEBHOOK }}
    defaults:
      run:
        working-directory: tofu/network
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: "1.10.0" }
      - name: init
        run: |
          tofu init \
            -backend-config="endpoint=${B2_S3_ENDPOINT}" \
            -backend-config="bucket=${TOFU_STATE_BUCKET}" \
            -backend-config="key=${TOFU_STATE_KEY}" \
            -backend-config="region=us-west-002" \
            -backend-config="skip_credentials_validation=true" \
            -backend-config="skip_metadata_api_check=true" \
            -backend-config="skip_region_validation=true" \
            -backend-config="skip_requesting_account_id=true" \
            -backend-config="use_lockfile=true" \
            -backend-config="force_path_style=true"
      - name: plan with detailed exit code
        id: plan
        continue-on-error: true
        run: |
          tofu plan -input=false -detailed-exitcode
          echo "exitcode=$?" >> $GITHUB_OUTPUT
      - name: notify on drift
        if: steps.plan.outputs.exitcode == '2'
        run: |
          curl -fsS -X POST -H 'Content-Type: application/json' \
            -d '{"content":"⚠️ tofu/network drift detected (network plan reports changes). Investigate: https://github.com/jaxzin/jaxzin-infra-bootstrap/actions"}' \
            "${{ secrets.DISCORD_WEBHOOK }}"
      - name: notify on error
        if: steps.plan.outputs.exitcode == '1'
        run: |
          curl -fsS -X POST -H 'Content-Type: application/json' \
            -d '{"content":"🛑 tofu/network drift check failed (plan errored). Investigate: https://github.com/jaxzin/jaxzin-infra-bootstrap/actions"}' \
            "${{ secrets.DISCORD_WEBHOOK }}"
```

The Discord messages do NOT include the drift diff itself — surfacing record names/IPs in a public channel reproduces the leak the design avoids elsewhere. The link to the workflow run is enough; the operator opens it to see redacted/private details.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/health-check.yml
git commit -m "ci(github): daily drift-detection for tofu/network"
```

---

### Task 8: First plan + apply (operator-driven, one-time)

This task is **not** code; it's the procedure for the first apply. Document it here so the operator picking up the plan knows exactly what to do.

- [ ] **Step 1: Confirm all Secrets are set**

In BOTH the GitHub repo settings AND the homelab Gitea repo settings, confirm every Secret listed in `tofu/network/README.md` step 2 of "One-time operator setup" exists and has a value.

- [ ] **Step 2: Open a PR**

After Tasks 1–7 are committed on the feature branch, open a PR. The `network` workflow runs on the PR — expect:
- `tofu fmt`, `init`, `validate` succeed.
- `tofu plan` runs against the live controller and shows `Plan: 1 to add, 0 to change, 0 to destroy.` (creating the Gitea record).
- The "Plan summary" step posts only the count summary; no diff body.

If plan shows changes other than 1-add-0-change-0-destroy, the controller has pre-existing static-DNS state. Decide whether to:
- Import the existing record (`tofu import 'unifi_dns_record.this["<name>"]' <id>`) and re-plan to confirm zero diff.
- Or accept the plan and let tofu reconcile.

- [ ] **Step 3: Merge**

Merge the PR to `main`. The `apply` step runs, the `dig` verification confirms propagation.

- [ ] **Step 4: Smoke-test**

Run from a LAN client (not the runner):

```bash
dig +short <gitea-lan-fqdn>
# expect: <gitea-lan-ip>
```

```bash
ssh -T -p <gitea-lan-ssh-port> git@<gitea-lan-fqdn>
# expect: Gitea SSH banner (Hi there, ... or Permission denied (publickey) on first connect)
```

These confirm DNS + the Plan #1 LAN-bind both resolve end-to-end.

- [ ] **Step 5: Coordination handoff (issue #5 spec)**

Per issue #5's coordination notes, the HA-IaC session resumes from this point. Send the chosen Gitea LAN SSH port back to that session via the agreed-upon channel — but do NOT include the actual port number, FQDN, or IP in any github.com-mirrored artifact (commit messages, PR descriptions, comments). Reference Secret names only on the github side.

---

### Task 9: Run the regression / drift check at least once before declaring done

- [ ] **Step 1: Trigger `health-check.yml` manually** (workflow_dispatch if available, or wait for next scheduled run).

- [ ] **Step 2: Confirm the `network-drift` job runs and reports no drift**

Expected: the job exits cleanly with no Discord message (exit code `0` from `tofu plan -detailed-exitcode`).

- [ ] **Step 3: Negative-test by creating a manual drift**

In the UniFi UI, *temporarily* add a static DNS record by hand (something throwaway, e.g., `nxtest.lan.${LAN_DOMAIN} → 192.0.2.99`).

- [ ] **Step 4: Re-trigger the drift workflow**

Expected: Discord receives the drift alert. The `network-drift` job exits non-zero.

- [ ] **Step 5: Clean up the manual drift**

Remove the throwaway record from the UniFi UI. Re-trigger the workflow. Expected: silent (exit `0`).

- [ ] **Step 6: Document completion**

Tick the relevant checkbox on issue #5 / coordinate with the HA-IaC session.

---

## Out of scope for this plan

- Managing port forwards, firewall rules, VLANs, DHCP reservations on UniFi. Module structure leaves room (sibling `.tf` files in the same module), but no work in this plan.
- Centralizing all `*.${LAN_DOMAIN}` records in this repo. Each service repo owns its own slice (see `tofu/network/README.md` "Layering rule" section).
- Migrating to UniFi API-key auth (over username/password). Deferred until firmware is stable on a release that supports it.
- External / public DNS via DNSimple. Already managed elsewhere via certbot.

## Out of scope, but unblocked by this plan

- Future repos copying `tofu/network/` to manage their own LAN DNS records (sourcing creds from OpenBao, per the layering rule).
