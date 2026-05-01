---
created: 2026-05-01
type: roadmap
tags: [second-brain, roadmap]
---

# Phasing and Roadmap

Drivers: features over scaling. Build the system *I* want first. Don't
make wasteful design choices, but don't refuse features because they
won't scale to a million users on day one.

## Phase 1 — Self-hosted MVP
- Self-hosted server, no E2E.
- Server-side embeddings + vector DB.
- MCP + OpenAPI surface with OAuth2.
- Filesystem-canonical storage; SQLite sidecar index.
- Schema registry v1 with a small set of built-in types
  (Note, Task, CalendarEvent, Transaction, Conversation).
- Desktop app (macOS first) with filesystem watcher connector.
- Browser extension for capture + connector suggestions.
- Goal: I can use it daily across my agent fleet.

## Phase 2 — Client-side E2E
- Client-side embeddings + client-side vector DB.
- E2E encrypted sync of vectors and content.
- iOS + iPadOS apps.
- Compatible with Phase 1 storage layout.
- Detailed metrics dashboard for embedding/query latency, battery, model
  download size — to decide if Phase 3 is worth it.

## Phase 3 — Managed offering with enclave compute
- Remote attested enclave for server-side semantic search over E2E data.
- Hosted MCP/API surface usable without losing E2E guarantee.
- macOS native polish, Windows app.
- Public open-spec release for the storage format.

## Phase 4+ — Extensibility
- Connector marketplace.
- User-defined schemas.
- Graph/entity-resolution layer (graphify integration).
- Power-user "off-the-rails" mode.
