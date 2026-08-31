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
Plan.md §12, plus §5's prompt capabilities. Create `Sources/FoundationModelsACPAgent/Agent/PromptContent.swift`.

- Advertise the prompt capabilities honestly at `initialize`. Text is the unconditional MUST. Advertise `image`, `audio` and `embeddedContext` only when the roster can act on them. On day one that likely means text and `embeddedContext` only. Decide from what the composed session really consumes, and keep the advertisement in one place next to the consumption code.
- `resource_link` is not capability-gated and can always arrive. Resolve a `file://` URI inside the session's root set. Refuse every other scheme and every out-of-bounds path with a reason. Never fetch `http://` silently (§12).

**Resolve through the files verb, not through a guard type.** `PathGuard` is internal in Multitool and cannot be named. Call `tools.files.read` and let the capability refuse an out-of-root path. The refusal arrives in band through the output's `correction` field, because the files verbs return corrections and do not throw. Turn that correction into the reasoned refusal we send.

- `embeddedContext` resources (`TextResourceContents` and `BlobResourceContents`) fold into the turn's content. `Annotations` are safe to ignore on input.
- MCP tool-result content maps straight to `tool_call_update.content`, because ACP's ContentBlock IS MCP's (§12). This is a type-to-type map in the projection.

- [ ] The capability advertisement matches real consumption
- [ ] `file://` resolution through the files verb, in bounds only
- [ ] Non-file schemes and out-of-bounds paths refused with a reason
- [ ] The files `correction` field is turned into the refusal message
- [ ] MCP content-block passthrough map

## Acceptance Criteria
- [ ] A prompt with a `resource_link` to a file inside the cwd puts the file text into the turn's content, received by the scripted backend
- [ ] A `resource_link` to `http://…`, or to a path outside the root set, is refused with a reasoned message, and no fetch or read happens
- [ ] The initialize response's prompt capabilities match exactly the content kinds the prompt path accepts, asserted by a test that enumerates both sides

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/PromptContentTests.swift` — harness, with temp files inside and outside the root set
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.