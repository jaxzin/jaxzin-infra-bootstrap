---
created: 2026-05-01
type: architecture
tags: [second-brain, storage, schema]
---

# Storage and Schema Strategy

## Principle
Native at-rest format **is** the open export format. No conversion step.

## Layout
- **Filesystem is canonical.** Inspired by Git: content-addressable IDs,
  working tree of files, sidecar index.
- **Markdown + YAML frontmatter** for prose, notes, journal entries.
- **Typed JSON/JSONL records** for structured data (transactions, calendar
  events, emails, health metrics, social posts, sensor data) following a
  **versioned schema registry**.
- **Binary attachments** stored alongside, referenced by stable ID.
- **Stable IDs** — UUIDv7 (time-sortable) or content hash for immutable
  records. Cross-references use these IDs, not paths.

## Sidecar index
- SQLite or DuckDB for relational queries.
- Tantivy / SQLite FTS5 for keyword search.
- Vector DB (LanceDB? sqlite-vec? hnswlib?) for semantic search.
- **Rebuildable from filesystem rescan.** Filesystem watching is an
  optimization, not a correctness dependency. Missed fsevents reconcile on
  next scan, like `git status`.

## Schema registry
- Built-in types: `Note`, `Task`, `Transaction`, `Email`, `CalendarEvent`,
  `HealthMetric`, `Conversation`, `Bookmark`, `Photo`, ...
- Versioned (`schema: transaction.v1`).
- User-extensible (later phase).
- Published as the open spec. JSON Schema or similar.

## Open spec angle
This is a potential differentiator. Document:
- The folder layout convention.
- The schema registry.
- The ID and reference scheme.
- A reference validator.

If others adopt it, vaults become portable across providers. ActivityPub-
style "second brain protocol."

## What is NOT solved by W3C/standards bodies today
- Solid is closest in spirit but unopinionated and thin in adoption.
- No turnkey standard for typed personal data + prose + attachments + index.
- Closest patterns to borrow: Git (CAS + working copy), Obsidian (md+fm),
  Anytype (object protocol, but proprietary format).
