# gitea_server

Deploys and manages the homelab Gitea server and its MySQL database. See `meta/main.yml` for the full argument spec.

## Manually-managed state (TODO: capture as code)

Some Gitea repository-level state on the homelab Gitea instance is currently configured manually via the UI rather than as code. After a full DR (Gitea data restored from backup), the restored state already includes these — they only need re-applying after a *zero-state* bootstrap (e.g., a fresh test environment).

| Item | Where | Notes |
|---|---|---|
| Deploy key on `fallen-leaf/home-assistant` (`homeassistant-config-deploy`) | Gitea UI → repo → Settings → Deploy Keys | Public key lives at `/config/.ssh/gitea_id_ed25519.pub` on the HA host. Tracked for IaC capture in issue #7. |

If you find yourself adding a *second* item to this table, that's the trigger to design and ship a Gitea-API-driven pattern (Ansible role or Tofu module) — see the tracking issue.
