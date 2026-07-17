# Gitea Stack: Kubernetes Migration — Design

**Date:** 2026-07-17
**Status:** Proposal — needs decisions in §6 before this becomes an implementation plan
**Tracking issues:** none yet (deliberately — this doc exists to get the open decisions answered first)

---

## 1. Context

Over the past two weeks the Gitea stack has had three separate outages that trace to the
same structural cause: `gitea` runs `network_mode: container:tailscale-gitea`, sharing the
sidecar's Linux network namespace so Tailscale Serve can use its kernel TUN device. Nothing
couples the two containers' *lifecycles* — only their netns is shared, once, at container
start. Any restart of `tailscale-gitea` (autoheal, a DNS-watchdog healthcheck failure, a
manual bounce) creates a **new** namespace while `gitea`'s process stays pinned in the old
one. Docker reports `gitea` "healthy" throughout (its own healthcheck runs *inside* the
stranded namespace and answers fine) while every external request 502s. See
[jaxzin/jaxzin-infra-bootstrap#148](https://github.com/jaxzin/jaxzin-infra-bootstrap/issues/148)
and PR #149 (merged, deployed 2026-07-07), which added a `stack_reconcile` watchdog step that
detects and auto-heals this within ~90–150 seconds. It works — the 2026-07-17 recurrence
self-healed with no manual intervention — but it's a fast *recovery*, not a fix for the
*cause*.

Zooming out, the same session that diagnosed #148 surfaced a pattern: a meaningful fraction
of this repo's Ansible is spent hand-rolling things a container orchestrator provides
natively — dependency-ordered health-gated restarts, daemon-restart survival, cron
scheduling that doesn't corrupt itself on redeploy. That code is well-engineered and
extensively commented (this repo's Ansible is genuinely good), but it exists to compensate
for the gap between "a pile of `docker_container` tasks" and "a real orchestrator." The
question this doc exists to answer: is closing that gap with Kubernetes worth the switch,
and if so, how do we get there without risking the one service everything else in the
homelab's disaster-recovery sequence depends on?

This is a **design proposal**, not a plan. It surfaces the real fork points and makes
recommendations; it does not commit to an implementation until §6 is answered.

## 2. Goals / Non-goals

**Goals**

- Eliminate the netns-sharing failure class structurally, not just auto-heal it faster.
- Replace hand-rolled self-healing (`stack_reconcile`, `container_manager_config`) with
  orchestrator-native mechanisms (controllers, probes) wherever they're a clean fit.
- Preserve the DR properties this repo currently guarantees: bootstrap-from-scratch via a
  single documented manual seed, restore-from-B2-backup, and the OpenBao
  non-circularity rule (this repo is Wave 1 of fleet DR; OpenBao is Wave 2 and is *not*
  available yet when this stack first comes up — see
  [DR_RECOVERY_GUIDE.md](../../DR_RECOVERY_GUIDE.md) and
  [gitea-runner-host.md](../runbooks/gitea-runner-host.md)).
- Keep the migration reversible and rehearsed before any real cutover — this is the
  fleet's tier-1 service.

**Non-goals (this doc)**

- Multi-node / HA Kubernetes. Nothing about this workload needs it at homelab scale, and it
  adds real complexity (etcd/datastore quorum, cross-node networking) with no payoff yet.
- GitOps (Argo CD / Flux). A nicer end-state, materially bigger lift, another thing to keep
  alive. Deferred, not rejected.
- Migrating anything beyond the Gitea stack itself. The user has floated migrating other
  services too — that's real, but deserves its own design pass once this one has proven
  the pattern. Flagged as Phase 4 in §5 and left unscoped.
- Changing the CI runner's architecture. It already solved its own version of this problem
  (see §4) and doesn't need touching.
- Deciding MySQL vs. Postgres definitively. Recommended, not decided (§4, §6).

## 3. Why "Kubernetes on the NAS" isn't the actual proposal

The obvious-sounding framing — "run k3s on the Synology NAS" — doesn't survive contact with
reality. DSM lacks the `overlay` containerd snapshotter kernel module, several iptables
modules k3s depends on (`ipt_REJECT`, `xt_comment`) aren't loaded and DSM has no `modprobe`
(only `insmod`, so module load order has to be solved by hand), and DSM ships neither
`systemd` nor `openrc`, which k3s's install and service-management path assumes. Hobbyist
writeups exist that get k3s running on Synology anyway via cross-compiled kernel modules and
custom containerd config — but that's precisely the genre of fragile, undocumented,
hand-rolled workaround this migration is trying to get *away* from, not back into.

So the real proposal is: **move Gitea off the NAS onto a Kubernetes-capable Linux host, and
let the NAS do what it's actually good at** — bulk storage, Btrfs snapshots, Hyper Backup —
instead of being asked to be a fragile compute platform for a moving-parts app stack. That's
a bigger scope decision than "add a k8s role," and it's the first thing in §6, not an
assumption baked into the rest of this doc.

## 3b. The bootstrap-primacy constraint — this can veto the whole migration

Raised by the operator on review (2026-07-17), and it's the strongest argument against
migrating at all: **Gitea is the bootstrap root for the entire network.** The whole fleet's
DR design leans on this repo's stack being recoverable with an absolute minimum of
moving parts. Today, Wave-1 recovery needs exactly: GitHub (cloud-hosted), B2 (cloud-hosted),
one seeded self-hosted runner box (the single documented manual seed), a NAS with Docker,
and Ansible over SSH. Every dependency is either someone else's uptime problem or a single
plain Linux box. That minimalism is not an accident — it's the design.

Inserting Kubernetes into that path means Wave-1 recovery now requires standing up a
functioning cluster (control plane, CNI, storage provisioner, Tailscale Operator) *before*
the fleet's git server exists. Each of those is another thing that can be broken, version-
drifted, or half-remembered at exactly the moment everything else is already on fire. A
migration that makes the tier-0 bootstrap *harder to resurrect from nothing* defeats its own
purpose, no matter how many watchdog scripts it deletes.

If the migration proceeds anyway, these are the non-negotiable guardrails that preserve the
property:

1. **k3s provisioning must live in this repo's GitHub-Actions layer** — the same
   Ansible-over-SSH path that deploys Docker containers today must be able to take a bare
   Linux host to "k3s up + manifests applied" with zero Gitea involvement. Gitea CI must
   never become the thing that deploys Gitea's own platform (same non-circularity rule as
   OpenBao, one layer down).
2. **The cluster must be boring:** single node, embedded datastore (SQLite), no external
   etcd, no cluster-level dependencies that aren't in this repo. Anything fancier belongs in
   Wave 2+.
3. **DR Recovery Method 1 must stay a two-workflow story** ("run Bootstrap, run Restore") with
   **no new manual seeds** beyond today's single one. This is the measurable acceptance
   criterion: if the k8s path adds a third manual step to the DR guide, it has failed this
   constraint and the migration should be rejected or reworked.
4. **The rehearsal in Phase 2 must start from a bare OS**, not from a lovingly hand-nursed
   cluster — otherwise it doesn't test the property this section exists to protect.

**And the alternative that honors this constraint best is to not migrate the bootstrap at
all:** fix the netns-coupling problem *within* the Docker world (e.g., couple the sidecar
and Gitea lifecycles explicitly, or terminate Tailscale outside the container stack) and
reserve Kubernetes for Wave-2 fleet services, where a cluster dependency is architecturally
harmless. That option is now Decision 0 in §6 — it's the real fork, and everything else in
this doc is conditional on it.

## 4. What Kubernetes fixes vs. what it doesn't

### Fixes cleanly

| Current hand-rolled mechanism | Native Kubernetes replacement | Notes |
|---|---|---|
| netns-stranding + `stack_reconcile`'s netns-reconcile step (#148/#149) | Pod-shared network namespace | All containers in a Pod share one netns **for the Pod's lifetime** — a sidecar restart is a Pod restart, both containers cycle atomically. Eliminates the failure class structurally rather than detecting-and-healing it. |
| `stack_reconcile` Step 2 (orphan revival, dependency order) | Deployment/StatefulSet controller + restart policy | Native reconciliation loop; no hand-rolled `docker inspect` polling script. |
| `stack_reconcile` Step 3 (gate: wait for `gitea-db` healthy before restarting `gitea`) | `readinessProbe` + init ordering | No hand-rolled "wait for X healthy" loop. |
| `container_manager_config` (live-restore, log-driver hardening, Synology-CM-restart survival) | N/A — the *problem* doesn't exist off DSM | This role is a Synology-specific antibody to a Synology-specific disease (DSM auto-updates restarting the Container Manager daemon out from under everything). On a normal Linux host, it's not a role to migrate — it's a role to delete. |
| `syno_crontab` append-only-`lineinfile` footgun (three separate roles purge legacy cron lines before scheduling) | `CronJob` | Declarative and idempotent; the "purge stale entries" dance stops being necessary because there's nothing to accumulate. |

### Improves, but isn't a guaranteed fix

- **`dns-watchdog.sh`** (the empty-`DefaultResolvers`-on-boot bug + periodic `accept-dns`
  bounce) — the [Tailscale Kubernetes
  Operator](https://tailscale.com/docs/kubernetes-operator) manages proxy Pods' Tailscale
  lifecycle as an actively maintained upstream project rather than a home-grown script, and
  its proxy Pods are narrower-scoped than a general sidecar. But the underlying `tailscaled`
  bug this script works around could in principle still surface. Treat this as "probably
  better, needs a soak test," not "solved."
- **Secrets management** — `gitea`'s own credential material (`internal_token`,
  `api_token.txt`, the JWT persisted in `app.ini`) is currently plain host files (mode
  0600/0640), not OpenBao-managed — OpenBao today is used narrowly, only for an optional
  OIDC-source self-heal token. Kubernetes `Secret` objects are a lateral move by themselves
  (still something has to populate them — either the CI deploy job, same as today, or an
  operator syncing from OpenBao). **The non-circular DR constraint still applies**: this
  stack is Wave 1 of fleet DR, OpenBao is Wave 2, so Gitea's *own* bootstrap secrets can
  never depend on OpenBao being up yet. That constraint is unchanged by this migration and
  must be respected by whatever secret mechanism is chosen.

### Doesn't fix / genuinely new cost

- **New failure domain.** Even single-node k3s is a control-plane process Gitea's uptime
  now rides on. A k3s bug or crash is a new outage class that doesn't exist in "just run
  `docker run`." Mitigated by k3s being small (CNCF-certified, single binary, ~400–500MB RAM
  idle) — a much smaller surface than what it replaces — but not zero.
- **Kernel-mode Tailscale requirements don't disappear.** Tailscale Serve/SSH need
  `CAP_NET_ADMIN`, `CAP_SYS_MODULE`, and `/dev/net/tun` — exactly why the current design
  shares a netns in the first place. The Tailscale Operator supports this pattern (it's a
  documented, supported use case), but it still needs an explicit `securityContext` and
  **won't run under a restrictive/default `PodSecurity` admission policy**. Worth stating
  plainly rather than hand-waving past it.
- **The socket-mounted CI runner has no clean Kubernetes mapping**, and this is the single
  most consequential *unresolved* design question the inventory turned up — except it isn't
  actually a question this migration needs to answer, because the runner already solved its
  own version of this exact class of problem: it moved off the NAS onto its own dedicated,
  tailnet-joined Linux host, running with `network_mode: bridge` (never netns-shared — this
  is regression-locked in `tests/check_docker_tasks.py` Check E) and socket-mounted Docker,
  fully decoupled from the sidecar-sharing pattern entirely. **Recommendation: leave the
  runner exactly where and how it is.** It is not in scope for this migration.
- **MySQL vs. Postgres.** The [official Gitea Helm
  chart](https://gitea.com/gitea/helm-chart) dropped its bundled MySQL/MariaDB dependency
  chart (Postgres is the only bundled option now; external MySQL is still *supported*, just
  not chart-managed). Two paths:
  - **(a) Self-manage a MySQL StatefulSet** — keeps the current DB engine and the
    already-proven `gitea dump`/`gitea-restore.yml` migration path; more YAML we own
    ourselves.
  - **(b) Migrate to Postgres** — less to self-manage long-term, chart-maintained, but a
    database engine migration is its own project with its own dump/restore validation,
    stacked on top of a platform migration.

  **Recommendation: (a) for the initial migration**, to avoid stacking two risky migrations
  at once. Revisit Postgres later, as a separate, smaller project, once the platform itself
  has soaked.
- **Storage backend.** k3s's default, `local-path-provisioner`, needs zero setup but ties
  data to whichever single node it lands on. For a genuinely single-node cluster that's not
  a *functional* problem (there's only one node anyway), but it does mean the compute
  node's local disk becomes as load-bearing as the NAS's disk is today. **NFS from the
  existing NAS** is the more natural fit — it keeps the NAS doing the storage job it already
  does well, and decouples "where compute runs" from "where data lives," which is exactly
  the flexibility this migration is trying to gain. Recommend NFS; revisit only if a
  genuinely multi-node cluster becomes real (Longhorn etc. — explicitly not needed at this
  scale, don't build for it early).
- **New skill surface**: kubectl / YAML manifests / Helm, on top of the Ansible/Docker
  patterns already deeply understood here. Real and non-zero, though arguably more
  transferable than Synology-specific Ansible.
- **The CI/CD deploy shape needs a Kubernetes-shaped equivalent.** Today:
  `dawidd6/action-ansible-playbook` running `ansible-playbook gitea-deploy.yml` from GitHub
  Actions, unchanged in structure since this repo's inception. The direct swap is `kubectl
  apply` / `helm upgrade` from the same GitHub Actions job — smallest possible diff from a
  pattern that's proven and trusted. GitOps (cluster pulls instead of CI pushes) is a nicer
  long-term shape but is explicitly deferred (§2 non-goals).

## 5. Target shape (once §6 is answered)

| Today (Docker/Ansible on the NAS) | Proposed (Kubernetes) |
|---|---|
| `tailscale-gitea` container, kernel-mode sidecar | Tailscale Operator-managed proxy, same Pod as `gitea` |
| `gitea` container, `network_mode: container:tailscale-gitea` | `gitea` container, same Pod as the Tailscale proxy (native shared netns) |
| `gitea-db` (`mysql:8`) | MySQL `StatefulSet` + PVC (NFS-backed, per §4 recommendation) |
| `stack-reconcile` watchdog container | *(deleted — replaced by controller + probes)* |
| `container_manager_config` role | *(deleted — problem doesn't exist off DSM)* |
| `gitea_backup`'s `syno_crontab`-scheduled dump | `CronJob` running the same `gitea dump` → B2 upload logic |
| `certbot`'s `syno_crontab`-scheduled renewal | Unaffected — certs are consumed by the Tailscale Serve config or `cert-manager`, TBD at implementation time; not a blocker for this design |
| `gitea-runner` (CI runner) | **Unchanged.** Stays on its own dedicated host, outside the cluster. |
| 0600 host-file secrets (tokens, JWT, B2/DNSimple/webhook creds) | Kubernetes `Secret`s, populated by the CI deploy job (same trust boundary as today; OpenBao sync deferred, non-circularity constraint preserved) |

## 6. Open decisions — need your answer before this becomes a plan

0. **Does the bootstrap root migrate at all?** (§3b — this gates everything below.)
   - **(a) Migrate Gitea to k8s** under the §3b guardrails (k3s provisioned from the GitHub
     layer, single-node/boring, no new manual seeds, bare-OS rehearsal).
   - **(b) Keep the bootstrap on plain Docker; take Kubernetes to Wave 2 instead.** Fix the
     netns-coupling bug inside the Docker world, and let the *rest* of the fleet — where a
     cluster dependency can't poison DR Wave 1 — be the k8s adopters. Gitea stays the
     deliberately boring root.
   - *My recommendation:* **(b)** is the safer reading of this homelab's own design
     philosophy, and it still gets you Kubernetes where it's harmless. Choose (a) only if
     you value consolidating on one platform enough to accept a heavier tier-0 resurrection
     path — and hold it to §3b's acceptance criterion ruthlessly.

1. **Where does k3s actually run?** (§3)
   - **(a) The existing `GITEA_RUNNER_HOST`** — already dedicated, tailnet-joined,
     Docker-capable, with SSH/CI wiring already in place. Reuses trusted infrastructure, but
     its current job is exclusively "run the CI runner," and I don't know its headroom for
     also running Gitea + DB + a cluster control plane. Also: putting the CI runner and the
     thing it deploys to on the *same* node changes today's deliberate machine-separation
     story for DR blast radius.
   - **(b) A new, dedicated host** — cleanest separation, avoids the co-location risk above,
     but is new hardware and a budget/space call only you can make.
   - **(c) Multi-node k3s across existing boxes** — the "proper" eventual answer, explicitly
     not recommended for the first cut (§2 non-goals).
   - *My recommendation:* (a) if headroom checks out, else (b). This is genuinely your call.
2. **MySQL (self-managed StatefulSet) vs. Postgres (chart-native)?** Recommend MySQL for the
   initial migration (§4); Postgres is a good *later*, separate project.
3. **Storage backend for PVs?** Recommend NFS from the existing NAS (§4).
4. **CI deploy mechanism?** Recommend scripted `kubectl`/`helm apply` from the existing
   GitHub Actions job (smallest diff); defer GitOps.
5. **Timeline/urgency.** This is the fleet's tier-1, DR-Wave-1 service. Recommend treating
   "rehearse a full restore onto the new cluster before any real cutover" (§7 Phase 2) as
   non-negotiable regardless of how much schedule pressure exists.
6. **Aside, not blocking the migration decision:** `autoheal` (`willfarrell/autoheal`) is
   running live on the NAS today but isn't deployed by this repo's Ansible — it predates or
   sits outside this repo's IaC. That's a standing violation of this homelab's own
   "no manual/unmanaged infrastructure" convention, and it's part of the very restart-loop
   problem class this migration exists to get away from (it's what actually executed the
   sidecar restarts in the #148 and 2026-07-17 incidents). Worth a decision independent of
   the Kubernetes timeline: adopt it into IaC, or retire it outright once the netns-sharing
   pattern it keeps tripping over is gone.

## 7. Recommended phasing (once §6 is answered)

**Phase 0 — Spike (near-zero risk).** Stand up k3s on the chosen host. Prove: clean boot,
survives a reboot, the Tailscale Operator joins the tailnet and can Serve a trivial test
workload. No production traffic touches this. Goal: de-risk the platform choice before
committing Gitea's data to it.

**Phase 1 — Low-stakes pilot.** Build real operational muscle memory with
kubectl/Helm/the Tailscale Operator on something disposable *before* touching git data.
Explicitly **not** the CI runner (§4 — it already works, is fully decoupled, don't
manufacture homework for a solved problem). A synthetic smoke-test workload, or a genuinely
low-stakes Wave-2 fleet service, is a better candidate. The goal here is proving the deploy
pipeline shape (CI → kubectl/helm → cluster), not finding something real to risk.

**Phase 2 — Gitea + DB migration, rehearsed before cutover.** The elegant part: the
*existing* B2 backup/restore mechanism (`gitea dump` / `gitea-restore.yml`) is already a
portable, host-agnostic migration vehicle — it's literally today's documented DR Recovery
Method 1 (bootstrap fresh, then restore data). Rehearse a full restore onto the new cluster
from a real B2 backup **while the NAS's Gitea stays live and authoritative** (a
parallel, non-destructive dry run). Verify repos, users, webhooks, and CI history integrity
on the restored copy. Only then do a real cutover during a planned maintenance window: stop
the NAS's Gitea, take a final backup, restore onto the cluster, flip Tailscale Serve/DNS,
decommission the NAS containers.

**Phase 3 — Retire the Synology Ansible/Docker path**, once the Kubernetes deployment has
soaked for a defined period (name a real number when you get here — e.g. 2–4 weeks of
stability — not "whenever it feels ready"). Delete `stack_reconcile`,
`container_manager_config`, and the Docker-container Tailscale-sidecar role for Gitea; drop
the `tafeen.synology` cron/package usage for this stack specifically. The NAS's role narrows
to what it's actually good at: Btrfs snapshots (Tier 1 DR, untouched), NFS storage for k8s
PVs (if §6.3 chose NFS), and Hyper Backup (Tier 2, untouched).

**Phase 4 — explicitly out of scope here.** Migrating the rest of the fleet beyond Gitea,
which the user has floated wanting. Deserves its own design pass once this migration has
proven the pattern in production. Not scoped, not estimated, not assumed.

## Sources consulted

- [Tailscale Kubernetes Operator docs](https://tailscale.com/docs/kubernetes-operator) and
  [architecture reference](https://tailscale.com/docs/kubernetes-operator/concepts/architecture)
- [k3s storage / local-path-provisioner docs](https://docs.k3s.io/add-ons/storage)
- [Official Gitea Helm chart](https://gitea.com/gitea/helm-chart)
- Community writeups on running k3s on Synology DSM (feasibility negative — missing kernel
  modules, no systemd; treated as corroborating evidence, not authoritative)
