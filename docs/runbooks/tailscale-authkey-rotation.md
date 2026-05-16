# Runbook: Rotate the Tailscale sidecar auth key (`TS_AUTHKEY`)

## When to run this

A deploy fails with one of these (added for Gitea #25):

- "did not authenticate (BackendState=NeedsLogin/NoState/NeedsMachineAuth) …
  classic expired/revoked TS_AUTHKEY signature"
- "registered but NOT routing … TS_AUTHKEY is likely expired/revoked"

Or: consumer deploys (e.g. obsidian-mcp) fail with `ssh: … Network is
unreachable` to a tailnet host that is independently verified healthy.

## Why this happens

`jaxzin-infra-bootstrap` runs **persistent** Tailscale sidecars
(`tailscale-gitea`, `tailscale-runner`; `restart_policy: always`). They
authenticate with a single key from the `TS_AUTHKEY` CI secret
(`playbooks/vars/main.yml` → `tailscale_sidecar` role env).

**Persistent nodes must use a reusable, NON-ephemeral auth key.** An
ephemeral key deauthorizes and removes its node as soon as the node goes
offline (a restart, a NAS reboot, a brief outage). The node then cannot
re-authenticate on next start → "worked for days, then silently died".
Ephemeral keys also expire (often ≤ 90 days). Either failure mode presents
identically: the sidecar never reaches `Running`, the proxy can't route,
and consumer SSH / tailnet-proxied traffic fails downstream.

## Correct key type (set this when minting)

In the Tailscale admin console → **Settings → Keys → Generate auth key**:

- **Reusable:** yes (multiple sidecars + redeploys reuse it).
- **Ephemeral:** **NO.** These are long-lived persistent nodes.
- **Expiration:** the longest your policy allows; record the expiry date in
  the team calendar / tracker so rotation is scheduled, not reactive.
- **Tags:** apply the tag your tailnet ACL grants the sidecars' required
  routes (so "registered" also means "authorized to route"). Confirm the
  ACL grants that tag a path to the consumer targets (e.g. the `gaming`
  host class). A tag with no ACL route reproduces "registered ≠ routing".

Never commit the key. It lives only in the CI secret store.

## Rotation steps (operator)

1. Mint a new key with the settings above. Copy it once.
2. Update the secret in **both** places (this repo is the bootstrap layer
   and is the only repo permitted to read CI secrets directly — both
   mirrors must match):
   - GitHub: `gh secret set TS_AUTHKEY --repo jaxzin/jaxzin-infra-bootstrap`
     (paste the key at the prompt).
   - Gitea mirror: set the `TS_AUTHKEY` Actions secret on the mirror repo
     via the Gitea UI (Settings → Actions → Secrets) or API.
3. Trigger a deploy (`Bootstrap` workflow on GitHub, or the Gitea
   `Deploy Gitea` workflow). The fail-fast assertions in the
   `tailscale_sidecar` role will now pass instead of erroring; if they
   still error, the new key's type/tags are wrong — re-check
   "Correct key type".
4. Revoke the old key in the admin console once the deploy is green.

## Verify end to end

1. Deploy is green; sidecar bring-up logs
   `Tailscale sidecar '…' is Running with a usable tailnet route (N peers)`.
2. Re-trigger the affected consumer deploy (e.g. obsidian-mcp). Its
   Ansible `PLAY RECAP` for the tailnet-targeted host shows
   `unreachable=0`.

## Lifecycle (so this can't silently recur)

- The `tailscale_sidecar` role assertions convert a dead key into an
  immediate, named deploy failure — it can no longer fail silently four
  plays downstream.
- Record the key's expiration and rotate ahead of it.
- If the tailnet policy supports it, prefer an OAuth client / tagged key
  with a managed lifecycle over a hand-minted expiring key.
