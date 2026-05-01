---
created: 2026-05-01
type: architecture
tags: [second-brain, permissions, mcp]
---

# Permission and Agent Access Model

## Granularity
Standard MCP scope model: scopes allow/block specific **tool calls**.
No filtering on data structure or argument values in v1.

- `read:notes`, `write:notes`, `read:transactions`, etc.
- Read-only and read-write scopes per tool category.

## Authorization
- OAuth2 for agent connections.
- User approves scopes per agent at connection time.
- Revocation surfaces in the desktop/web app.

## Out of scope for v1
- Per-record ACLs.
- Tag/sensitivity-based filtering.
- Per-request user approval flows.

These can be added later if real demand emerges.

## Note: the privacy story is about *the pipe*, not the agent
The architectural goal is that even a malicious hosting provider cannot
sit between the user/agent and their data. Once the user authorizes an
agent, that agent has whatever scopes it was granted. See
[[Second Brain - Trust and Encryption Model]].
