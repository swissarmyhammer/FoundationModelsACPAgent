---
assignees:
- claude-code
depends_on:
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: todo
position_ordinal: '8880'
title: 'MCP composition: config servers, client mcpServers, elicitation decline fallback'
---
## What
Plan.md §7.3, §11.2 (mcp entry), §11.5, §16 (interim only). Create `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift`:

- Compose two sources into the `withMCP(servers:)` entries of the ToolCatalog build: config-derived `mcp:` servers first, then client-supplied per-session `mcpServers` (session scope, **never persisted** — `session/resume` re-supplies them, §7.3). ACP's `name` maps to `ServerIdentity`.
- **Decide and document the open §7.3 collision rule** — recommended: a client-supplied server whose name collides with a config-derived server is **refused with a logged error** (config is the user's committed intent; silent replacement would let a connecting editor shadow a trusted server). Record the decision in a doc comment and in plan.md §7.3.
- Transports: `McpServerStdio` → `StdioServerProcess`, `McpServerHttp` → `HTTPClientTransport` with ACP `headers` as auth (§11.5). `env`/`headers` are arrays of `{name, value}`; duplicate names — last wins. No SSE. The ACP tunnel (`mcp/connect` etc.) is unstable-schema-only: do NOT build it.
- Connection completes **before** `buildRegistry()` and thus before the composed pair reaches `makeSession(tools:)` (§7.3, §11.4) — expose an async `connect` step the session/new task awaits. A later server change starts a registry rebuild, and MultiTool swaps the new surface in at the next turn boundary (eventplan).
- `mcp: false` → fully off AND client-supplied servers refused with a logged reason (§11.2).
- Interim elicitation (§16): provide a coordinator conforming to Multitool's `ElicitationCoordinator` (the host seam of `ToolContext.elicit`) that **declines every request** with the reason "this host cannot ask you questions yet". The real `ACPElicitationCoordinator` is blocked on wire tasks `7kgq5dw`/`enzjy0q`.

- [ ] Two-source composition, config first
- [ ] Collision rule decided + documented in plan.md
- [ ] Connect-before-makeSession sequencing
- [ ] `mcp: false` refuses client servers with a log
- [ ] Declining `ElicitationCoordinator` fallback

## Acceptance Criteria
- [ ] Given config servers A,B and client servers C — provider order is A,B,C
- [ ] Client server named A (collision) is refused per the documented rule; session still starts
- [ ] With `mcp: false`, client-supplied servers produce zero tools and one logged refusal
- [ ] Elicitation requests resolve as decline with the stated reason
- [ ] Nothing about client servers appears in `sessions.jsonl`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift` — composition/collision/refusal against stub server descriptions (no real processes); elicitation fallback unit test
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.