---
assignees:
- claude-code
depends_on:
- 01KYSV93N6D4RWYQ7XMCHQ21GW
- 01KYSVA1A4HXA6RYSJBE2XERFM
- 01KYSV611EWFQQRRPJWR5JQ4H5
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: todo
position_ordinal: '9880'
title: 'Tier-2 integration suite: the five proofs with real tools'
---
## What
Plan.md §20.1 tier 2 — real `ToolCatalog`, real FileTool/Shelltool, real `RoutedACPAgent`, real `session/new(cwd)` on a temp directory, scripted model. Create `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` proving, from the client end:

1. **Composition** — ToolCatalog constructed each tool with the correct ToolContext (root set, decoded config section).
2. **Confinement through the protocol** — ask `files` for an out-of-root path; observe the refusal in the tool_call_update.
3. **Projection** — a real tool call becomes a correct tool_call_update: stable toolCallId, `in_progress` → `completed`, filled `locations`, `rawInput`/`rawOutput`, title on first report.
4. **Turn order** — `{}` → `user_message` → `running` → tool updates → `idle(end_turn)`.
5. **Enable/disable** — project config `shell: false` ⇒ no shell tool reaches the session, confirmed from the client end.

Discipline: **check the filesystem, never the transcript** — a "file written" claim is verified by reading the file from disk (§20.1). No MLX, no download, no gates; runs at every commit.

Also: when FoundationModelsMCP's `4egfvw3` (MCPTestServerCLI/ScriptedServer) lands, add the free MCP case — spawn the scripted server, list tools, call one, assert tool_call_update correlation. If not landed when this task runs, note it as a follow-up checklist item left unchecked with a comment on the task.

- [ ] Proof 1: composition
- [ ] Proof 2: confinement via the wire
- [ ] Proof 3: projection fidelity
- [ ] Proof 4: turn order
- [ ] Proof 5: enable/disable

## Acceptance Criteria
- [ ] All five proofs pass in plain `swift test` on any host
- [ ] The write-a-file proof reads the actual bytes from disk
- [ ] Suite runs ungated in CI

## Tests
- [ ] This task IS tests: `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — this suite may drive fixes in earlier components; keep those fixes in this task only when trivial, else file follow-up tasks.