---
created: 2026-05-01
type: architecture
tags: [second-brain, ingestion, data-model]
---

# Data Model and Ingestion

## Core principle: capture-first, infer-later
- The second brain **must never lose data.**
- Multiple representations of the same real-world entity (e.g., a flight in
  Gmail, Calendar, TripIt, voice note) are **all preserved separately,
  with provenance.**
- Entity resolution / linking is a **secondary, non-authoritative** layer
  added in a later phase. Inferred relationships are surfaced as
  suggestions, not truth.
- Pluggable: integrate with graph tools (graphify, alternatives) for
  entity inference. Especially for self-hosted users.

## Source-of-truth modes per item
1. **Canonical** — created in the second brain (a thought, a decision,
   notes from a conversation with an agent). Authoritative.
2. **Persistent cache/archive** — external system but kept forever
   ("deleted my Twitter, kept the archive"; "closed Citi, kept 20 years
   of transactions").
3. **Transient mirror** — currently active external system (today's Apple
   Notes, this week's calendar). May expire/sync.

Each item carries a flag indicating its mode + provenance.

## Agent conversations
- Treated as canonical source-of-truth bearing items.
- Captured for cross-provider continuity: continue a conversation thread
  on a different LLM via **retrieval**, not import/migration.
- This is itself a feature.

## Ingestion / connectors framework
- Pluggable "exporter/connector" architecture in desktop and web apps.
- Plan for both **batch/offline export** and **realtime watch/capture**
  per provider — depends on what each provider exposes.
- Initial connectors envisioned:
  - Filesystem watcher (desktop) — scan and watch the user's drive.
  - Browser extension — capture browsing, suggest connectors based on
    sites visited ("I see you use citi.com, try the Citibank connector").
  - Email (IMAP / Gmail API).
  - Calendar (CalDAV / Google Calendar).
  - Agent conversation capture (Claude/ChatGPT exports, MCP tool that
    agents call to write back).
- Open connector SDK so power users / community can add more.
