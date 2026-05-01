---
created: 2026-05-01
type: open-questions
tags: [second-brain, open-questions]
---

# Open Questions

## Trust & encryption
- How do we make client builds verifiable (web especially)? Reproducible
  builds? Third-party attestation? Native-only for managed tier?
- Key recovery without provider escrow: Shamir? Social recovery?
  Hardware-key bound?
- Which metadata, if any, can be intentionally non-E2E to enable
  server-side features pre-Phase 3? (titles? schema type? timestamps?)

## Storage & schema
- JSON Schema vs CUE vs custom DSL for the schema registry?
- ID scheme — UUIDv7 vs content hash vs both?
- How do we version schemas without breaking older vaults?

## Ingestion
- For each connector: batch export vs realtime capture vs hybrid?
- Conflict policy when the same external item changes?
- Retention/expiration policy for transient mirrors.

## Agent access
- Do we need *any* finer-grained access control before launch, or is
  pure tool-scope enough?
- How do we handle agent-to-agent delegation safely?

## Business
- Pricing model for managed tier (storage? users? agent calls?).
- Licensing (BSL terms, commercial-use threshold, contributor agreements).
- Trademark/brand.
