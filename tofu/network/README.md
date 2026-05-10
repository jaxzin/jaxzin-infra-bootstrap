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
