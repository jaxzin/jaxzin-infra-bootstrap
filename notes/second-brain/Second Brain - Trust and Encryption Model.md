---
created: 2026-05-01
type: architecture
tags: [second-brain, security, e2e-encryption]
---

# Trust and Encryption Model

## Threat model goal
Even a **malicious hosting provider** cannot read user data or MITM the
client. The user and their authorized agents have access; nothing in
between, ever. This is the core marketing story.

## Tiers
- **Self-hosted (BSL/OSS)** — E2E not required; user runs the server.
- **Managed** — E2E mandatory.

## Phases for E2E + semantic search
- **Phase 1:** Self-hosted, no E2E. Server-side embeddings & vector DB.
  Unblocks MVP and early dogfooding.
- **Phase 2:** Client-side embeddings + client-side vector DB. Encrypted
  embedding vectors synced/stored E2E. Compatible with Phase 1 data.
  Capture detailed metrics: embedding latency on mobile, battery, model
  download size, query latency.
- **Phase 3 (gated by Phase 2 metrics):** Remote enclave compute (e.g., AWS
  Nitro, GCP Confidential Space, Apple Private Cloud Compute pattern) for
  server-side semantic search over encrypted vectors. Worth the complexity
  only if Phase 2 hits a wall on UX.

## Hard problems (acknowledge, do not pretend solved)
- **Verifiable client builds.** A malicious provider could ship a
  backdoored web app. Mitigations: signed native builds, reproducible
  builds, third-party audits, possibly subresource integrity for web. This
  is the same gap 1Password/Bitwarden/Proton have not fully closed.
- **Hosted MCP/API access vs E2E.** Server needs *some* plaintext to serve
  agent requests. Options:
  - Some metadata (titles? frontmatter?) intentionally not E2E.
  - Hosted MCP/API blocked until Phase 3 enclaves are real.
  - Until then: self-hosted only for full agent access.
- **Key management & recovery** — user loses key = data lost. Need a
  Shamir/social-recovery story. Add to [[Second Brain - Open Questions]].

## Reference designs to study
- 1Password's secret key + master password model.
- Apple Private Cloud Compute (attestation + ephemeral compute).
- Signal's sealed sender, contact discovery via SGX.
- Tuta / Proton encryption-at-rest patterns.
