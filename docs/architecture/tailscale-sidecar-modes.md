# Tailscale Sidecar Networking Modes

## Context

This repo deploys two Tailscale sidecars: one in front of Gitea, one in front of the Gitea Actions runner. They look symmetric, but they use **two different Tailscale networking modes** because their service profiles are different. The choice has non-obvious blast radius: when in doubt, the wrong choice usually shows up as "containers can reach tailnet but not LAN" — or vice versa.

This doc captures the trade-off so future reviewers don't have to re-discover it.

## The two modes

### Kernel mode + `network_mode: container:<sidecar>`

```
┌──────────────────────────────────────────────┐
│ Sidecar's network namespace                  │
│                                              │
│   tailscale0 (kernel TUN, from Tailscale)    │
│   eth0      (Docker bridge attachment)       │
│   lo                                         │
│                                              │
│  ┌────────────────────┐  ┌─────────────────┐ │
│  │ tailscale-gitea    │  │ gitea           │ │
│  │ (sidecar process)  │  │ (consumer; uses │ │
│  │                    │  │  this namespace │ │
│  │                    │  │  via network_   │ │
│  │                    │  │  mode:container)│ │
│  └────────────────────┘  └─────────────────┘ │
└──────────────────────────────────────────────┘
```

**Profile:**
- The sidecar binds a kernel `TUN` device (`/dev/net/tun`) and runs Tailscale in kernel mode.
- The consumer container joins via `network_mode: container:<sidecar-name>`, sharing the namespace exactly.
- Both processes see the same interfaces: `tailscale0`, the Docker bridge attachment, and loopback.
- Tailscale Serve, Tailscale SSH, exit-node, subnet-router — all the kernel-feature stuff — works here.

**Trade-off:**
- Consumer's outbound traffic is filtered through the sidecar's view: only what the sidecar can route is reachable.
- LAN access depends on the Docker bridge attachment, NOT on `tailscale0`. The default route inside the namespace is the Docker bridge gateway, which routes via host → eth0 → LAN.
- BUT: **dind-spawned child containers inherit the sidecar's namespace transitively, and dind's own auto-created bridges sit inside that namespace.** A child container's NAT chain becomes: `child → dind auto-bridge → dind gateway → sidecar namespace → bridge attachment → host → LAN`. Each hop is a NAT-translation opportunity, and the host-side iptables `FORWARD` chain has to permit the flow at every step. In our environment (Synology DSM), the LAN-bound flow drops somewhere in this multi-hop NAT chain while `tailscale0`-routed traffic — which bypasses the chain entirely — continues to work. The exact dropping link wasn't pinpointed; restrictive host firewall rules and missing MASQUERADE registrations for nested-bridge subnets are plausible culprits, but on stricter or differently-configured hosts the failure surface may differ. **Result: child containers can reach the tailnet but not the LAN.**

This is exactly the failure mode that motivated this doc. See "The bug" below.

### Userspace mode + standalone-network sidecar with proxy

```
┌──────────────────────────────────────────────┐
│ gitea-net Docker bridge                      │
│                                              │
│  ┌────────────────────┐  ┌─────────────────┐ │
│  │ tailscale-runner   │  │ gitea-runner    │ │
│  │  TS_USERSPACE=true │  │  HTTPS_PROXY=   │ │
│  │  exposes :1099 /   │◄─┤    http://      │ │
│  │  :1055 as proxy    │  │    tailscale-   │ │
│  │  to peers          │  │    runner:1099  │ │
│  └────────────────────┘  └─────────────────┘ │
│                                              │
└──────────────────────────────────────────────┘
        │                          │
        │                          │
   tailnet via                LAN via host's
   userspace WireGuard        gitea-net → eth0
```

**Profile:**
- Sidecar runs Tailscale in userspace networking mode (`TS_USERSPACE=true`). No kernel TUN device required.
- Sidecar exposes Tailscale connectivity to peers via:
  - SOCKS5 proxy on `:1055` (`TS_SOCKS5_SERVER`)
  - HTTP CONNECT proxy on `:1099` (`TS_OUTBOUND_HTTP_PROXY_LISTEN`)
- Consumer container sits on the same Docker bridge as the sidecar — NOT in its namespace.
- Consumer sets `HTTPS_PROXY=http://tailscale-runner:1099` (and `ALL_PROXY=socks5://...:1055` for tools that don't speak `HTTP_PROXY`).
- Outbound traffic to the tailnet (e.g., `gitea.<tailnet>.ts.net`) routes through the sidecar's proxy, exits the sidecar's userspace Tailscale connection.
- Outbound traffic to anything else (LAN, internet) routes the normal Docker way: container → bridge → host → host's egress interface.

**Trade-off:**
- Loses Tailscale Serve, exit-node, and subnet-router features (those need kernel TUN).
- Application clients must honor `HTTPS_PROXY`/`ALL_PROXY` env vars. Most modern HTTP/HTTPS clients do (Go's `net/http`, Python `requests`, `curl`, `git`, `wget`, etc.).
- Tools that don't honor proxy env vars (some SSH clients, native protocols) won't reach the tailnet through this setup unless they're configured explicitly.

## Which to use, when

| Workload | Mode | Reason |
|---|---|---|
| Service that **publishes** to the tailnet via Tailscale Serve / SSH | Kernel + `network_mode: container:<sidecar>` | Serve/SSH need kernel TUN |
| Service that needs **both tailnet AND LAN** access for its work | Userspace + multi-network + `HTTPS_PROXY` | Avoids the namespace-collapse LAN problem |
| Service that needs **only LAN/internet**, no tailnet | No sidecar | Sidecar adds latency for no benefit |
| Service that needs **only tailnet**, no LAN | Either works; kernel mode is slightly faster | Kernel mode bypasses one userspace hop |

### A fourth option: socket-mount instead of dind

For Docker-in-Docker workloads specifically (e.g., a CI runner that spawns
job containers), there's a fourth option worth naming: **drop dind entirely
and bind-mount the host's `/var/run/docker.sock` into the runner**. Job
containers then spawn directly on the host's Docker daemon — they sit on
real Docker networks the host knows about (e.g., `gitea-net`), inherit
embedded DNS, and avoid every problem above (the LAN-multi-hop-NAT
problem, the dind-daemon DNS gap, the certs-volume mismatch).

**Why we don't do this here:** Socket-mounting gives every job container
root-equivalent authority over the host's Docker daemon — a job can
spawn privileged containers, mount the host filesystem, or stop the
runner itself. For **multi-tenant or hostile-job scenarios** this is
unacceptable. For our **homelab single-tenant** setup where every
workflow runs trusted IaC, the isolation trade-off is acceptable, and
socket-mount is on the table as a future simplification.

This is a deliberate trade-off, not a free improvement: name it
explicitly when revisiting.

## The bug this prevented

**Symptom:** A CI workflow's job container tried to resolve `unifi<lan-domain-suffix>` (a LAN hostname). DNS lookup timed out at 3 seconds. Same container could reach `100.100.100.100` (Tailscale's MagicDNS) in milliseconds.

**Tracing the network state from inside the failing container:**

- `/etc/resolv.conf`: `nameserver 127.0.0.11` (Docker embedded DNS) — normal.
- Upstreams configured on the embedded DNS: `[LAN_DNS 100.100.100.100]` — correct.
- TCP probe to LAN_DNS:53: **timeout after 3s** — packet never arrived at UniFi.
- TCP probe to 100.100.100.100:53: **immediate connect** — Tailscale routing works.
- TCP probe to a known-public hostname (B2): timed out at DNS resolution — same path going through LAN_DNS, same failure.

**Root cause:** The runner (`gitea-runner`) shared its namespace with `tailscale-runner` via `network_mode: container:tailscale-runner`. The dind dockerd inside `gitea-runner` spawned job containers on auto-created bridges (`172.21.0.0/16`) nested inside the sidecar's namespace. The sidecar's namespace has `tailscale0` and a `gitea-net` Docker bridge attachment. Traffic to `100.x` matched a Tailscale-installed route and went via `tailscale0`. Traffic to `192.168.x.x` had to NAT through the host — but the chain of MASQUERADE rules from `dind auto-bridge → sidecar namespace → gitea-net bridge → host eth0` failed somewhere in the host's iptables `FORWARD`/`POSTROUTING` chains. Synology DSM is a likely culprit (restrictive default firewall), but the underlying issue is **the multi-hop NAT chain through a kernel-mode sidecar is fragile and OS-dependent.**

**Fix:** Move the runner sidecar to userspace mode and put the runner directly on `gitea-net`. The runner now reaches the tailnet via the sidecar's `HTTPS_PROXY`, and reaches the LAN directly through the host's normal Docker → bridge → eth0 path. dind's nested auto-bridges still exist, but they sit on top of `gitea-net` (not the sidecar's namespace), so the host's MASQUERADE rule for `gitea-net → eth0` covers them.

## Generalizable lesson

**The `network_mode: container:<X>` pattern collapses the consumer's network to whatever `<X>` can route to.** It works beautifully for services that have a single, well-defined egress need (e.g., Gitea publishing on the tailnet via Tailscale Serve). It is a footgun for services that need multi-destination routing, especially when those services then *spawn child containers* (dind, runner job containers, nested compose stacks). In those cases, prefer userspace mode + proxy.

The rule of thumb: **if a container ever needs to talk to both the tailnet AND the LAN (or even the public internet via a non-tailscale path), don't share its namespace with a kernel-mode Tailscale sidecar.**

### Follow-up: the dind-daemon DNS gap

A second, related gotcha lives one layer deeper: even with userspace mode + multi-network, **dind-spawned job containers don't see the parent Docker network's embedded DNS.** The embedded dind dockerd inside `gitea-runner` creates its own internal bridge network for job containers; that network has its own embedded resolver, which knows nothing about peer containers on the outer `gitea-net`. So even though `gitea-runner` itself can resolve `tailscale-runner` via gitea-net's DNS, job containers it spawns cannot. Workflows that try to hit the userspace proxy (`http://tailscale-runner:1099` / `socks5://tailscale-runner:1055`) fail at DNS resolution.

**Quick fix (current implementation):** Capture the sidecar's `gitea-net` IP at deploy time (via `community.docker.docker_container_info`) and inject `--add-host=tailscale-runner:<IP>` into the act_runner's `container.options`, which is applied to every job container. Brittle if the sidecar restarts and Docker hands it a new IP from its DHCP pool — re-running the playbook re-captures and reconciles. Acceptable for the current single-runner scale.

**Permanent fix (future):** Drop dind entirely and mount the host's `/var/run/docker.sock` into the runner. Job containers would then live on `gitea-net` directly and inherit its embedded DNS, eliminating the gap. The trade-off is isolation: socket-mount gives job containers the same Docker authority as the host. For homelab single-tenant CI that's acceptable; for multi-tenant or hostile-job scenarios it isn't. See the "Which to use, when" table for the broader socket-mount discussion.

## References

- [Tailscale userspace networking docs](https://tailscale.com/kb/1112/userspace-networking)
- Diagnostic PR that surfaced this: PR #24 on the self-hosted Gitea instance (`https://gitea.<tailnet>/jaxzin/jaxzin-infra-bootstrap/pulls/24`)
- The 4 hotfix PRs (`#20`–`#23`) that chased CI symptoms before this root cause was identified
- Brian's `fix/gitea-runner-job-container-docker-access` (PR #79) and `fix/gitea-runner-cert-bind-mount` (PR #80) — runner config fixes that are independent of this sidecar topology fix
