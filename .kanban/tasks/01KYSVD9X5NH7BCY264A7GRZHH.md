---
assignees:
- claude-code
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: todo
position_ordinal: '9580'
title: 'Prompt content: honest capabilities and resource_link resolution'
---
## What
Plan.md §12 (+§5's prompt capabilities). Create `Sources/FoundationModelsACPAgent/Agent/PromptContent.swift`:

- Advertise prompt capabilities honestly at `initialize`: text is the unconditional MUST; advertise `image`/`audio`/`embeddedContext` only when the roster can act on them (day one that likely means text + embeddedContext only — decide from what the composed session actually consumes, and keep the advertisement in one place next to the consumption code).
- `resource_link` (not capability-gated, can always arrive): resolve `file://` URIs **inside the session's root set** through the `files` tool; refuse every other scheme and every out-of-bounds path **with a reason** (no silent `http://` fetches — §12). `PathGuard` is the arbiter.
- `embeddedContext` resources (`TextResourceContents`/`BlobResourceContents`) fold into the turn's content. `Annotations` safe to ignore on input.
- MCP tool-result content → `tool_call_update.content` keeps the shape (ACP's ContentBlock IS MCP's — §12); this is a straight type-to-type map in the projection.

- [ ] Capability advertisement matches actual consumption
- [ ] `file://` resolution through files/PathGuard, in-bounds only
- [ ] Non-file schemes and out-of-bounds refused with reason
- [ ] MCP content-block passthrough map

## Acceptance Criteria
- [ ] A prompt with a `resource_link` to a file inside cwd: the turn's content includes the file text (scripted backend receives it)
- [ ] A `resource_link` to `http://…` or to a path outside the root set → the turn errors (or the block is refused with a reasoned message) and no fetch/read occurs
- [ ] Initialize response's prompt capabilities exactly match the content kinds the prompt path accepts (a test enumerates both sides)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/PromptContentTests.swift` — harness; temp files in/out of the root set
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.