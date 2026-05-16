# Runbook: job-container ssh-to-tailnet (static SOCKS5 helper)

## What this is

Gitea #25 remaining defect: after the userspace-sidecar refactor
(`1bd3b788`), a dind-spawned CI job container has **no tailnet route and
no MagicDNS**. `ssh` does not honor `*_PROXY`, so a plain
`ssh host.<tailnet>` (e.g. obsidian-mcp deploying to `gaming.<tailnet>`)
resolves to public junk and fails `ENETUNREACH`.

Fix: the `gitea_runner` role bind-mounts, into every job container:

- a **static `socat`** at `/usr/local/bin/ts-socks5`
- an ssh snippet at `/etc/ssh/ssh_config.d/10-tailnet-proxy.conf` that
  sets `ProxyCommand` for `Host *.<tailnet>` to route through the
  userspace Tailscale sidecar's SOCKS5 server (`tailscale-runner:1055`).

socat sends the **hostname** to the SOCKS5 server, so the sidecar — which
*is* on the tailnet — does the MagicDNS resolution **and** the routing.
The job container resolves/routes nothing tailnet-side. Transparent to
consumers (no obsidian-mcp change).

## Required operator input (one-time, then on rotation)

No download URL is shipped in the repo on purpose — silently fetching a
binary that runs inside every CI job container is a supply-chain risk.
The operator pins a trusted static `socat`:

1. Obtain (or build) a **statically linked** `socat` for **linux/amd64**
   (the runner label set is `amd64`; job images are glibc Ubuntu, but a
   fully static binary runs regardless of libc). Verify it is static:
   `file socat` → "statically linked"; `ldd socat` → "not a dynamic
   executable".
2. Record its download URL and SHA-256.
3. Set both as CI **Secrets/Variables** consumed at deploy time
   (env vars read in `gitea_runner/defaults/main.yml`):
   - `GITEA_RUNNER_SOCKS_HELPER_URL`
   - `GITEA_RUNNER_SOCKS_HELPER_SHA256`
   Set them on **both** the GitHub repo and the Gitea mirror (this is the
   bootstrap layer — see the layering rule).
4. Trigger a deploy (`Bootstrap` workflow). The role asserts both are set
   (fails fast with this runbook's name if not), `get_url` fetches with
   `checksum: sha256:...` (deploy fails on mismatch — tamper-evident),
   and bind-mounts it.

## Verify end to end

- Deploy is green; `gitea-runner` recreated with the two new
  `-v ...ts-socks5...` / `...10-tailnet-proxy.conf...` mounts
  (`docker inspect gitea-runner`).
- Re-trigger the obsidian-mcp deploy. Its Ansible `PLAY RECAP` for
  `gaming` shows `unreachable=0` (previously `unreachable=1`).
- Spot check inside a job: `ssh -G gaming.<tailnet>` lists the
  `proxycommand ... ts-socks5 ... SOCKS5:tailscale-runner:...:1055`.

## Rotation / lifecycle

Re-pin (URL + SHA-256) when upgrading the helper; the `checksum:` makes a
changed artifact fail the deploy until the SHA is updated — intentional.
Keep the binary static; a dynamically linked build will fail in minimal
job images with an interpreter/libc error.

## Why not vendor the binary in git / hardcode a URL

Vendoring bloats the repo with a binary blob; hardcoding a URL means an
unreviewed, unpinned binary executes in every CI job. The pinned
URL+SHA-256 operator input is the same trust posture as the other
bootstrap-layer CI secrets (e.g. `TS_AUTHKEY`).
