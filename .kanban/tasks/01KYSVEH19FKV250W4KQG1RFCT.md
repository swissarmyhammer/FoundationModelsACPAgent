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
title: 'Tier-2 integration suite: the seven proofs with real tools'
---
## What
Plan.md §20.1 tier 2 — a real `ToolCatalog`, a real `MultiTool` with the files and shell capabilities, a real `RoutedACPAgent`, a real `session/new(cwd)` on a temp directory, and a scripted model.

Create `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`, proving these from the client end:

1. **Composition** — `ToolCatalog` built each capability with the correct `CatalogContext`: the root set and that capability's decoded config section. Assert through the built `APISurface` entries, because the per-verb argument and output structs are internal.
2. **Confinement through the protocol** — ask `tools.files.read` for a path outside the root set and observe the refusal in the `tool_call_update`. The files capability returns corrections **in band** through a `correction: String?` field on every result; it does not throw.
3. **Projection** — a real tool call becomes a correct `tool_call_update`: a stable `toolCallId`, `in_progress` then `completed`, filled `locations`, `rawInput` and `rawOutput`, and a title on the first report.
4. **Turn order** — `{}` → `user_message` → `running` → tool updates → `idle(end_turn)`.
5. **Enable and disable** — project config `shell: false` means no shell namespace reaches the session, confirmed from the client end.
6. **MCP** — spawn a real server, list its tools, call one, and assert the `tool_call_update` correlation. Assert the noun is the server name, as in `tools.<serverName>.<verb>`, with no `mcp` segment.
7. **Streamed shell output** — a real `tools.shell.execute` of a command that prints several lines with pauses. Assert, from the recorder, that `tool_call_content_chunk` updates arrive for that `toolCallId` before the terminal `tool_call_update`, in order, and that the terminal update's `content` equals the command's complete output (plan.md §8.4, §11.6). Assert, from `ACPSessionState.toolCalls`, that the final content equals that same output — the replace converged the container.

**Assert the tool names that ship today.** The session tools are `searchTools`, `runCode` and `wait`, plus the stand-alone `skills` tool. `findAPIs` no longer exists, and the surface is not a pair. Note Multitool's own README and eventplan still say `findAPIs` in prose; the code is authoritative.

**The MCP test support is shipped**, so proof 6 is not blocked. Multitool ships the `MCPTestServer` library and the `mcp-test-server` executable. `MCPTestServerCLI` is the old name and is gone, but **`ScriptedServer` still exists** — it is a `public actor` in the `MCPTestServer` library with its own self-test suite. Use it to script the server's answers rather than writing a stub.

**Drive and assert through `FoundationModelsACPClient`** (plan.md §20.1). The harness connects a `SwiftUIACPClient` over `InMemoryTransport.pair()`. Read proofs 2, 3 and 5 from `ACPSessionState`: `toolCalls[toolCallId]` carries `status`, `title`, `locations`, `rawInput` and `rawOutput`, so assert the projection there. Read proof 4 from the forwarding recorder, because the container keeps no arrival order. Call `flushPendingChunks()` before a text assertion.

Discipline: **check the filesystem, never the transcript.** Verify a "file written" claim by reading the file from disk (§20.1). No MLX, no download and no gates. It runs at every commit.

- [ ] Proof 1: composition
- [ ] Proof 2: confinement through the wire, read from the `correction` field
- [ ] Proof 3: projection fidelity
- [ ] Proof 4: turn order
- [ ] Proof 5: enable and disable
- [ ] Proof 6: MCP through `ScriptedServer`
- [ ] Proof 7: streamed shell output as `tool_call_content_chunk`, converged by the settlement replace

## Acceptance Criteria
- [ ] All seven proofs pass in a plain `swift test` on any host
- [ ] The write-a-file proof reads the real bytes from disk
- [ ] The suite runs ungated in CI

## Tests
- [ ] This task IS tests: `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — this suite can drive fixes in earlier components. Keep those fixes in this task only when they are trivial; otherwise file follow-up tasks.