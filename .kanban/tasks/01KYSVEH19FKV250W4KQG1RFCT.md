---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g9d63r47qtkrvb86hpjxz4
  text: |-
    ### research — discoveries

    - The harness is ready: `ScriptedTurnFixture` wires the recording harness, `initialize`, and one `session/new` on a temp cwd. The suite adds a project `config.yaml` writer and a `mcpServers` pass-through to `NewSessionRequest`.
    - Router derives `toolCall`/`toolStatus` events from the backend transcript diff (`RoutedSessionActorRecording.emitSessionEvents`). The scripted backend returns no entries, so no such event fires today. The SDK types `Transcript.ToolCalls`, `Transcript.ToolCall(id:toolName:arguments:)` and `Transcript.ToolOutput(id:toolName:segments:)` have public initializers (`TranscriptRecordingFixtures.swift` already constructs SDK entries). The fix: `ScriptedSessionBackend.invokeTool` appends a `.toolCalls` entry before the invocation and a `.toolOutput` entry after it, with deterministic ids `scripted-call-N`. That gives the wire `in_progress` then `completed`, `rawInput`, `rawOutput` and `title` for a real mounted tool call.
    - The mounted `runCode` is a background tool: the call answers a pending envelope, and the snippet runs in a background run. Each scripted tool turn plays `runCode` then `wait`, so the run settles inside the turn.
    - Tool paths: `files.read`, `shell.execute`, `&lt;serverName&gt;.&lt;verb&gt;` with no `mcp` segment. `journalOp` is "verb noun" ("read files", "execute shell"). The out-of-root correction contains "outside workspace boundaries" and never throws.
    - IMPORTANT — proof 7 vocabulary: the card says `tool_call_content_chunk`, but commit f29d183 (2026-09-02, task ^gmaxv6s, AFTER this card was written) moved shell bytes to the agent-owned terminal stream, exactly as plan.md §11.8 directs: "When the terminal stream lands, `shell` moves its bytes to `terminal_output_chunk` and the tool call carries a `terminal` reference". The suite asserts the landed vocabulary: `terminal_output_chunk` updates for the run's `terminalId` (= `toolCallId`) before the exit `terminal_update`, in order; the exit replacement equals the complete output; `ACPSessionState.terminals` converges; the settlement `tool_call_update` completes with the `Terminal` reference.
    - `locations` gap: no code path fills `tool_call_update.locations` today. The event vocabulary the projection receives (`toolCall`/`toolStatus`/`runSettled`) carries no path data; plan.md §11.5 says locations need the structured per-call record, which does not exist yet. That fix is not trivial, so a follow-up task will carry it, per this card's own workflow note.
  timestamp: 2026-09-02T05:27:57.304932+00:00
- actor: claude-code
  id: 01m1ga66rp6yw1wsmm6dfmb1kw
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift (new, the seven proofs), Tests/FoundationModelsACPAgentTests/Support/ScriptedModel.swift (the scripted backend now appends SDK `.toolCalls`/`.toolOutput` transcript entries around each played tool call, ids `scripted-call-N`, so Router's diff derives the `toolCall`/`toolStatus` events), Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift (optional `workingDirectory`, `projectConfigYAML` and `mcpServers` on `make`, plus `writeProjectConfig`).
    - findings along the way, filed as follow-up tasks: ^9jfmhh0 (`locations` never fills — no shipped event carries path data), ^yx45q1q (a nested background run's `runSettled` never reaches the wire; the shell call stays `in_progress` on the client), ^fzx2r16 (`shell.execute` with no `workingDirectory` runs in the agent PROCESS directory and the sandbox refuses it — the tier-2 snippet passes the session cwd explicitly).
    - what did not work: one `wait {}` after `runCode` does not join a nested shell run — the nested run registers only when the snippet resolves, after the first wait took its pending snapshot. The turn plays a second `wait {}`.
    - proof 7 asserts the LANDED terminal-stream vocabulary (plan.md §11.8, commit f29d183, task ^gmaxv6s): `terminal_output_chunk` for the run's `terminalId` (= `toolCallId`) in order, the exit `terminal_update` with the authoritative replacement equal to the complete output, and convergence in `ACPSessionState.terminals`.
    - tests: `swift test` → 276 tests in 28 suites passed, zero warnings, 1 pre-existing known issue (HarnessSmokeTests own withKnownIssue check).
    - next: /test, /commit, /review
    task: ^qg1rfct
  timestamp: 2026-09-02T05:41:37.174841+00:00
- actor: claude-code
  id: 01m1ga7qqff8afrhafkktvmmex
  text: |-
    ### test — green
    - evidence: `swift test` — 276 tests in 28 suites passed, 0 failed, 0 skipped; 1 known issue is HarnessSmokeTests' own deliberate `withKnownIssue` proof that `expectOrderedSubsequence` can fail (pre-existing). The one build line `warning: missing creator for mutated node (mlx-swift_Cmlx.bundle)` is a SwiftPM build-system artifact from the mlx dependency; it is present on the pristine tree with this diff stashed (verified), so this change adds zero warnings.
    - next: commit
  timestamp: 2026-09-02T05:42:27.311539+00:00
depends_on:
- 01KYSV93N6D4RWYQ7XMCHQ21GW
- 01KYSVA1A4HXA6RYSJBE2XERFM
- 01KYSV611EWFQQRRPJWR5JQ4H5
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: doing
position_ordinal: '80'
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

- [x] Proof 1: composition
- [x] Proof 2: confinement through the wire, read from the `correction` field
- [x] Proof 3: projection fidelity (see the note: `locations` moved to follow-up task ^9jfmhh0 — no shipped event carries path data)
- [x] Proof 4: turn order
- [x] Proof 5: enable and disable
- [x] Proof 6: MCP through `ScriptedServer`
- [x] Proof 7: streamed shell output, in the landed §11.8 terminal-stream vocabulary (`terminal_output_chunk` + exit replacement; the card wording predates commit f29d183)

## Acceptance Criteria
- [x] All seven proofs pass in a plain `swift test` on any host
- [x] The write-a-file proof reads the real bytes from disk
- [x] The suite runs ungated in CI

## Tests
- [x] This task IS tests: `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`
- [x] `swift test` → green

## Workflow
- Use `/tdd` — this suite can drive fixes in earlier components. Keep those fixes in this task only when they are trivial; otherwise file follow-up tasks.
- Follow-up tasks filed from this suite: ^9jfmhh0 (locations), ^yx45q1q (nested run settlement), ^fzx2r16 (shell default working directory).