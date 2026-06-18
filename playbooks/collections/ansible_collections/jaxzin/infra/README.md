# Ansible Collection - jaxzin.infra

Shared infrastructure roles for homelab services on Synology DSM with Tailscale networking.

## Roles

### `jaxzin.infra.tailscale_sidecar`

Deploys a Tailscale sidecar container with optional [Tailscale Serve](https://tailscale.com/kb/1312/serve) reverse proxy. The sidecar joins your tailnet and can expose services via HTTPS using Tailscale's built-in TLS.

**Supports two networking patterns:**

1. **Shared namespace** (default): The app container uses `network_mode: container:<sidecar>` to share the sidecar's network stack. Serve proxies to `127.0.0.1`.
2. **Docker DNS**: The app and sidecar are on the same Docker network. Serve proxies to the app's container name via Docker DNS. Set `tailscale_serve_proxy_host` to the app's container name.

#### Example: Shared namespace (default)

```yaml
- role: jaxzin.infra.tailscale_sidecar
  vars:
    tailscale_container_name: tailscale-myapp
    tailscale_hostname: myapp
    tailscale_authkey: "{{ lookup('ansible.builtin.env', 'TS_AUTHKEY') }}"
    tailscale_state_dir: /volume1/docker/myapp/tailscale-state
    tailscale_network_name: myapp-net
    tailscale_serve_enabled: true
    tailscale_serve_config_dir: /volume1/docker/myapp/tailscale-serve-config
    tailscale_serve_domain: "myapp.example.ts.net"
    tailscale_serve_proxy_port: "3000"
```

#### Example: Docker DNS (multi-container)

```yaml
- role: jaxzin.infra.tailscale_sidecar
  vars:
    tailscale_container_name: tailscale-myapp
    tailscale_hostname: myapp
    tailscale_authkey: "{{ lookup('ansible.builtin.env', 'TS_AUTHKEY') }}"
    tailscale_state_dir: /volume1/docker/myapp/tailscale-state
    tailscale_network_name: myapp-net
    tailscale_serve_enabled: true
    tailscale_serve_config_dir: /volume1/docker/myapp/tailscale-serve-config
    tailscale_serve_domain: "myapp.example.ts.net"
    tailscale_serve_proxy_host: "myapp-server"
    tailscale_serve_proxy_port: "9000"
```

## Installation

```bash
ansible-galaxy collection install jaxzin.infra
```

Or via `requirements.yml`:

```yaml
collections:
  - name: jaxzin.infra
    version: ">=1.0.0"
```

## Requirements

- Ansible >= 2.14
- `community.docker` collection
- Docker on the target host

## License

MIT
