---
created: 2026-05-01
type: concept
tags: [second-brain, vision]
---

# Vision and Wedge

## One-liner
A portable, agent-native personal memory store. Plugs into any agent via
MCP/OpenAPI. No dedicated UI required — though beautiful native apps exist
for when you want them.

## Why now / wedge
Existing players (Mem, Reflect, Capacities, Notion AI, Obsidian+plugins) are
all UI-first. They trap "everything about you" inside their own product and
the big AI platforms (Google/OpenAI/Anthropic/Apple) trap it inside theirs.

The wedge is **portability + privacy + agent-first**:
- Any agent can read/write via MCP/OpenAPI+OAuth2.
- E2E encrypted in managed tier; self-hostable for full control.
- Open at-rest format → users can migrate between providers.
- Strong opinions on organization → "it just works."

## Target user
Me, and agent-forward people like me. Comfortable with Claude connectors,
ChatGPT custom GPTs, MCP servers. Want Apple-style "it just works" polish.
Will trade configurability for ease in v1; extensibility comes later.

## Usage hierarchy
1. **Agent-first** — "Claude, add that to my todo list."
2. **Mobile-second** — quick check/capture on phone.
3. **Desktop-third** — deep dives, reorganization, power tasks.

If agent UX is excellent, mobile/desktop apps may be rarely used. That's fine.

## Aspirational scope
The "RAG source to end all RAG sources about you": financial, health, work,
recreational, education, media — all captured, all retrievable in
milliseconds by any agent the user authorizes.
