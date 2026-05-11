# UniFi Static DNS via OpenTofu — Design

**Date:** 2026-05-10
**Status:** Approved (pending user review of this written spec)
**Tracking issues:** #5 (deliverable #2) · #6 (sequencing prerequisite)

---

## 1. Context

Issue #5 deliverable #2 calls for a LAN-resolvable DNS record so that a service running inside this homelab — currently Gitea on the NAS, future-proofed for relocation — is reachable by name (`${GITEA_LAN_FQDN}`) from any LAN client. The record is served by the UniFi gateway's built-in static-DNS feature so it works for every client that uses the gateway as its resolver.

This is also the foundation for an internal LAN-only zone of similar records owned by *other* repos. Each repo manages its own slice; this repo owns only the records related to bootstrapping (currently one).

## 2. Goals / Non-goals

**Goals**

- Manage the LAN static-DNS record for `${GITEA_LAN_FQDN} → ${GITEA_LAN_HOST}` declaratively in code.
- Declare the *shape* (a list of records) so adding more records is a list-entry edit, not a code change.
- Use a tool well-suited to API-managed devices: drift detection, plan/apply lifecycle, schema-validated provider.
- Keep all topology (hostnames, IPs, controller URL, bucket name, tailnet) out of committed files; sourced from CI Secrets at run time.
- Provide a *portable module shape* that other repos can copy and reskin, while NOT exporting this repo's "credentials live in CI Secrets" pattern (which is a bootstrap-layer exception — see §9).

**Non-goals**

- Centralizing all `*.${LAN_DOMAIN}` records in this repo. Records owned by other services live in those services' repos.
- Managing UniFi anything-other-than-DNS (port forwards, firewall, VLANs). Out of scope; module structure leaves room for siblings later.
- External / public DNS (DNSimple is already managed elsewhere via certbot's DNS-01 challenge).
- A `vault`-provider integration. This repo intentionally cannot depend on OpenBao (see §9).

## 3. Architecture

```
jaxzin-infra-bootstrap/
├── playbooks/                       # existing Ansible (unchanged by this work)
└── tofu/
    └── network/                     # NEW: portable root module
        ├── versions.tf              # OpenTofu + provider version pins
        ├── backend.tf               # B2 S3-compat backend (config via -backend-config)
        ├── variables.tf             # all inputs; sensitive=true on credentials
        ├── providers.tf             # provider "unifi" block fed entirely from var.*
        ├── dns.tf                   # for_each over var.unifi_static_dns
        └── README.md                # module purpose, inputs, layering caveat
```

**Key decisions (decided in brainstorm):**

- **Tool:** OpenTofu (>= 1.10 for `use_lockfile`) + the `ubiquiti-community/unifi` provider (active fork; `unifi_dns_record` resource added in 0.41).
- **State backend:** Backblaze B2 S3-compat, in the existing backup bucket under a `tofu-state/` prefix; key `jaxzin-infra-bootstrap/network.tfstate`.
- **State locking:** `use_lockfile = true` (S3 conditional-write locks; no DynamoDB needed).
- **Auth to UniFi:** dedicated local UniFi admin user (universal across firmware versions). API-key auth deferred as a future improvement.
- **CI:** new workflow files at `.gitea/workflows/network.yml` and `.github/workflows/network.yml`; both run on the on-prem self-hosted runner (controller is LAN-only).
- **Lifecycle:** plan on PR, apply on push to `main`.
- **Secret/Variable split:** all new values live in **Secrets** (not Variables), because the GitHub mirror is public and Variables are not redacted in workflow logs. See §9 / issue #6.

## 4. Components

### 4.1 Tofu module — `tofu/network/`

| File | Responsibility |
|---|---|
| `versions.tf` | Pin `tofu >= 1.10`, `ubiquiti-community/unifi >= 0.41, < 1.0`. |
| `backend.tf` | Empty `backend "s3" {}` declaration; concrete settings (endpoint, bucket, key, region, skip-validation flags) supplied via `-backend-config=` at `init` time so no topology lives in this file. |
| `variables.tf` | `unifi_api_url` (string), `unifi_username` (string), `unifi_password` (string, sensitive=true), `unifi_site` (string, default `"default"`), `unifi_insecure` (bool, default `false`), `unifi_static_dns` (list of objects `{name, value, type}`, default `[]`). |
| `providers.tf` | `provider "unifi"` block; every field a `var.*` reference. |
| `dns.tf` | `resource "unifi_dns_record" "this"` with `for_each = { for r in var.unifi_static_dns : r.name => r }`. Map keying by `name` keeps Terraform addresses stable across list reorderings. |
| `README.md` | Module purpose, input contract, the bootstrap-layer caveat (see §9), and copy-into-another-repo guidance. |

### 4.2 CI workflows

| File | Trigger | Behavior |
|---|---|---|
| `.gitea/workflows/network.yml` | push to `main` touching `tofu/network/**`; PR touching same | PR: `fmt -check`, `init`, `validate`, `plan` (summary only — no full diff body posted; see §6). Push to `main`: same plus `apply -auto-approve`, then `dig` verification. |
| `.github/workflows/network.yml` | identical to above, on the GitHub mirror | Identical job graph. Exists so DR-after-NAS-loss can re-apply network state without depending on Gitea. |

Both run on the on-prem self-hosted runner. State is the single source of truth and is shared between the two workflow homes (same B2 backend, same key) — running from one side updates state visible to the other.

### 4.3 Health check (drift detection)

Daily scheduled workflow runs `tofu plan -detailed-exitcode`. Exit code `2` (drift) sends Discord alert via the existing `DISCORD_WEBHOOK` pattern. Either standalone (`network-health.yml`) or merged into the existing `health-check.yml` — preference is to merge for consistency with the existing daily-Discord pattern.

### 4.4 New Secrets

All under **GitHub Actions Secrets** and **Gitea Actions Secrets** (not Variables). Naming follows the existing `UPPER_SNAKE_CASE` pattern.

| Name | Purpose | Type |
|---|---|---|
| `UNIFI_API_URL` | Controller URL (contains LAN domain — topology, sensitive) | Secret |
| `UNIFI_USERNAME` | Dedicated local admin user for OpenTofu | Secret |
| `UNIFI_PASSWORD` | That user's password | Secret |
| `UNIFI_SITE` | Site identifier (typically `default`); kept as Secret for policy uniformity | Secret |
| `B2_S3_ENDPOINT` | B2 S3-compat endpoint URL (contains region) | Secret |
| `TOFU_STATE_BUCKET` | Bucket name for state. Initial value is the same as `B2_BUCKET_NAME` (state lives under a `tofu-state/` prefix in the existing backup bucket). Stored as a separate Secret so the values can diverge later (e.g., dedicated bucket) without touching workflow logic. | Secret |
| `TOFU_STATE_KEY` | Path inside bucket: `tofu-state/jaxzin-infra-bootstrap/network.tfstate` | Secret |
| `GITEA_LAN_HOST` | LAN IP for the Gitea record (re-used from issue #5 deliverable #1's plan) | Secret |
| `GITEA_LAN_FQDN` | Record name for the Gitea record (topology) | Secret |

The dedicated UniFi `tofu` admin user is created **once, manually**, in the controller UI (chicken-and-egg — you need an admin to create an admin). The README documents this as a one-time bootstrap step.

## 5. Data flow

1. **Trigger:** push to `main` touching `tofu/network/**` or PR touching same.
2. **Runner:** on-prem self-hosted runner picks up the job (UniFi controller is LAN-only).
3. **Secret injection:** workflow exports each Secret as `TF_VAR_*` for module variables and as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for the S3 backend. Done in a single env-mapping step with no shell echo.
4. **`tofu init`** with `-backend-config="endpoint=$B2_S3_ENDPOINT" -backend-config="bucket=$TOFU_STATE_BUCKET" -backend-config="key=$TOFU_STATE_KEY" -backend-config="use_lockfile=true"`.
5. **`tofu plan`** authenticates to the controller, fetches existing static-DNS records, diffs against `var.unifi_static_dns`. Saves binary plan file.
6. **PR mode:** workflow parses plan with `tofu show -json` and posts a *summary count* (e.g., "1 to add, 0 to change, 0 to destroy") as a PR comment. The full diff body is NEVER posted (would leak record names + IPs on the public mirror).
7. **Push-to-main mode:** `tofu apply` of the saved plan.
8. **Verification:** runner runs `dig +short ${GITEA_LAN_FQDN} @${LAN_DNS}` and asserts the result equals `${GITEA_LAN_HOST}`. Without this, a 200 from the controller followed by a propagation failure looks like success.
9. **State upload:** S3 backend persists updated state to B2 (versioned, encrypted at rest).

## 6. Error handling

| Failure | Symptom | Response |
|---|---|---|
| Controller unreachable | `plan`/`apply` HTTP timeout | Workflow fails. State unchanged. Operator retries when controller returns. |
| Bad credentials | Provider 401 | Workflow fails with clear error. Rotate `UNIFI_PASSWORD` Secret. |
| State backend unreachable | `init` fails | Workflow fails. Apply cannot proceed. |
| State drift (manual UI edit) | `plan` shows unexpected diff | Plan-on-PR catches before `apply`. Operator imports the manual change or reverts it. |
| `dig` verification fails | `apply` reported success but DNS doesn't resolve | Workflow fails as "applied but unverified." Re-run is safe (idempotent). |
| Plan output leaks via PR comment | Public PR comment contains topology | Mitigated upfront: workflow posts only a summary count, never the diff body. |

**Idempotency:** `unifi_dns_record` is fully idempotent. Re-running `apply` on unchanged state is a no-op.

**Rollback:** removing an entry from `var.unifi_static_dns` and pushing to `main` deletes the corresponding record on the next apply. Issue #5 explicitly requires this rollback shape.

**Migration safety (post-relocation):** changing `${GITEA_LAN_HOST}` to a new IP produces a 1-line plan (`~ value = "<old>" -> "<new>"`) — no resource recreation, no record gap during transition. Verified shape; #5 calls this out as a parameter-swap requirement.

## 7. Testing

**Unit (no controller required):**

- `tofu fmt -check`
- `tofu validate`
- `tofu init -backend=false && tofu plan -refresh=false -var-file=tests/fixtures.tfvars` — synthetic vars, catches type errors and missing inputs.

**Integration (controller required, runs on LAN runner):**

- PR job runs `tofu plan` against the live controller — exposes drift and shape errors before merge.
- Post-apply `dig` verification (described in §5 step 8).

**Drift / health (DR readiness):**

- Daily scheduled `tofu plan -detailed-exitcode`. Exit code `2` (drift) → Discord alert via the existing webhook pattern.

**One-time manual verifications (documented in spec, not automated):**

- From a LAN client (not the runner): `dig +short ${GITEA_LAN_FQDN}` returns the expected IP.
- `ssh -T -p <gitea_lan_ssh_port> git@${GITEA_LAN_FQDN}` reaches the Gitea SSH banner — proves DNS + the LAN-bind from #5 deliverable #1 are both wired.

## 8. Portability for downstream repos

The `tofu/network/` module is designed to be copy-able into any future repo that needs to manage its own slice of `*.${LAN_DOMAIN}` records — for example, a future HA-config repo for `homeassistant.${LAN_DOMAIN}` or an auth-stack repo for `auth.${LAN_DOMAIN}`.

What's portable:

- `versions.tf`, `providers.tf`, `dns.tf`, `variables.tf` shape — copy verbatim.
- `backend.tf` shape — copy verbatim, but change the state `key` (each repo gets its own state file).

What's NOT portable (and is intentionally repo-specific here):

- The CI workflow's secret-injection step. *This repo* sources credentials from CI Secrets because OpenBao isn't available during DR bootstrap. Downstream repos must source credentials from OpenBao (see §9).

The module README contains both pieces of guidance: how to copy the module body, AND a clear caveat that the secret-fetching mechanism in this repo's workflows is the *exception*, not the template.

## 9. Layering & the OpenBao exception

`jaxzin-infra-bootstrap` is the bootstrap layer of the IaC stack. It's the only repo permitted to source credentials directly from CI Secrets. Every other repo must source credentials from OpenBao at run time.

**Why:** OpenBao is the *second* thing deployed during disaster recovery (after this repo brings up Gitea + the runner). If any repo whose workflow runs *during* the bootstrap chain depended on OpenBao for its secrets, DR would have a circular dependency: OpenBao bootstrap needs secrets → secrets are in OpenBao → OpenBao isn't up → bootstrap stalls. This repo's permanent CI-Secrets exception is what gives the chain somewhere to start.

**How this design applies the rule:**

- The module body (`tofu/network/*.tf`) accepts credentials as variables; it has no opinion on where they come from.
- *This repo's* CI workflow fills those variables from CI Secrets. That step is the exception.
- *Downstream repos*' CI workflows fill those variables from OpenBao (e.g., via the `vault` provider's `vault_generic_secret` data source, or a pre-`tofu init` shim that fetches and exports `TF_VAR_*`). That step is the rule.

## 10. Sequencing & dependencies

- **Issue #6 should land first.** It moves existing Variables (`NAS_HOST`, `TS_TAILNET`, etc.) to Secrets. Implementing the present design before #6 lands risks creating a near-term inconsistency where new topology is correctly in Secrets but old topology is still in Variables.
- **Issue #5 deliverable #1 (Gitea LAN-SSH bind) is independent** of this design. It introduces `GITEA_LAN_HOST` (re-used here as the IP for the DNS record). Either order works, but most natural is #1 first so the DNS record points at a working LAN-bound SSH listener immediately on apply.
- **Issue #5 deliverable #3 (deploy-key-via-API) is unaffected** by this design.

## 11. Open questions / TBDs

None blocking. Documented for awareness:

- **API-key auth** instead of username/password is supported on recent UCG firmware. Not adopted in this design because the firmware-version compatibility surface is wider for username/password. Revisit when the controller firmware is stable on a release that supports it.
- **Drift workflow placement** — merge into existing `health-check.yml` vs. a new `network-health.yml`. Both are reasonable; preference is merge, but the writing-plans phase will commit to one.
- **Plan-summary parsing** — the simplest path is `tofu show -json plan.out | jq` to extract counts. A future improvement is to render a fully-redacted human-readable summary (resource type + action only, no addresses or values).
