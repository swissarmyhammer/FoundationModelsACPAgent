---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyyzmzkpvv98r3c4rwpvhrej
  text: 'Description updated by card 2p6913n (plan-only OperationOutcome mapping): the "Status vocabulary" bullet now derives terminal status from `OperationEvent.outcome` via the ONE total `OperationOutcome → ToolCallStatus` function of plan.md §8.4 (upstream: OperationTool `1ad4ydw`, Shelltool `jt19xwc`, MCP `zfp4a3j` — all landed, see §21). Added a matching subtask line and acceptance criterion for full-enum + unknown-value mapping. Structure otherwise unchanged.'
  timestamp: 2026-08-01T15:38:58.038179+00:00
- actor: claude-code
  id: 01m1fwtst3cnjk00ncs3yks1p0
  text: |-
    Research findings before implementation:
    - `SessionEvent` (Router, Session/SessionEvent.swift) has the 13 cases the card lists. The enum doc tells a consumer to write a `default` arm. A cross-module switch that lists all 13 cases plus a plain `default` compiles with zero warnings (verified with a two-module scratch compile), because a non-frozen imported enum can gain cases.
    - `OperationEvent` / `OperationOutcome` live in Extras; Router re-exports them through `Hosting/OperationVocabulary.swift`. `OperationOutcome.rawValue` for `timedOut` is `timed_out`. The memberwise init defaults `outcome` to nil with no validation — the defensive reads the card demands are necessary.
    - `ShellOutputEvent`, `ShellOutputSnapshot`, `ShellRawOutput` (Multitool, Shell/OutputChunkStream.swift) have public inits, so a test can construct them. `ShellOutputChunkStream.send`/`complete` are internal to Multitool — only the shell runner feeds a real stream. The projection therefore consumes the stream as a generic `AsyncSequence` of `ShellOutputEvent`, and takes a snapshot-provider closure for the settlement replace, so tests can inject both.
    - Multitool's `FileChange` / `FileChangeKind` are internal, and the files capability posts no operation events with change payloads yet. The move/copy direction mapping is therefore a total function this package owns over its own change description, into ACP `DiffChange` (`DiffPathPairChange {oldPath, path}` for move/copy, `DiffPathChange {path}` for add/delete/modify).
    - `TurnStart` has an internal init, so a synthetic stream cannot script `.turnStarted`; the harness-driven scripted turn covers that arm.
    - `ScriptedSessionBackend.transcriptEntries()` returns `[]`, so a harness turn never emits `toolCall`/`toolStatus`/`runSettled`; those arms are driven through `PromptTurn.drive(events:)` with synthetic streams, the pattern PromptTurnTests already uses.
    - The raw-JSON shape assertion follows the `InitializationTests` pattern: `InMemoryTransport.pair()` + `NDJSONCodec.frames(from:)` reading the agent side's real encoder output.
    - `PromptTurn` (from ^0svz8qf) holds the inline projection (`TurnProjection` + `handle`) to refactor into `EventProjection.swift`.
  timestamp: 2026-09-02T01:48:11.971920+00:00
- actor: claude-code
  id: 01m1fxxjfnk1faz2jyt7nvsmyv
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift (new: the one mapping — all 13 `SessionEvent` cases plus an `@unknown default` arm, the total `OperationOutcome -> ToolCallStatus` function with `_lost` and the `_` rule, defensive envelope reads, the shell `tool_call_content_chunk` mapping over `ShellOutputEvent` with UTF-8-with-replacement decode and gap notes, the snapshot-based settlement replace, the compaction `usage_update`, and the move/copy `oldPath`/`path` direction mapping), Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift (projection refactored out; `drive` now delegates to `EventProjection`; new `shellSnapshot` seam), Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift (new: 18 tests, one raw-JSON wire-shape test through `InMemoryTransport` + `NDJSONCodec`), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift (new: shared `SinkRecorder` / `makeSinkedTurn` / `makeEventStream` fixtures), Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift (uses the shared fixtures; the tool-event test now asserts the projected `tool_call_update` order)
    - notes: TDD followed — the suite failed to compile against the missing API first, then went green. `default` arms on cross-module enum switches produce "default will never be executed" warnings in this build, so every absorber arm is `@unknown default` (still the default arm the `SessionEvent` contract asks for). `swift test`: 197 tests, 0 failures, 1 pre-existing known issue (HarnessSmokeTests).
    - next: test step, then commit and review
    task: ^e2xerfm
  timestamp: 2026-09-02T02:07:11.349877+00:00
- actor: claude-code
  id: 01m1fxy7g51v4sb01nmxyz04qx
  text: |-
    ### test — green
    - evidence: swift test — 197 tests in 20 suites passed, 0 failed, 0 skipped; swift build --build-tests exits 0 with zero compiler warnings (the one "missing creator" line is pre-existing build-system noise, not a compiler warning). The "1 known issue" is the pre-existing deliberate `withKnownIssue` self-test in HarnessSmokeTests.
    - next: commit, then review
  timestamp: 2026-09-02T02:07:32.869656+00:00
- actor: claude-code
  id: 01m1fxzcx65ngt7sbzvqbmm4mz
  text: |-
    ### commit — changed
    - evidence: 0d5a878 feat(agent): project every Router SessionEvent to the wire in EventProjection (7 files, +1328/−162; local only, not pushed)
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-02T02:08:11.174679+00:00
- actor: claude-code
  id: 01m1fy539gd1f6gdvkvzy8rvkw
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — counts {findings: 0, confirmed: 0, refuted: 0}; 5 files reviewed, 2 .kanban files excluded by .reviewignore. No prior Review Findings sections. Task moved to done.
    - next: none
  timestamp: 2026-09-02T02:11:17.936668+00:00
- actor: claude-code
  id: 01m1fy5btm223frm9ps1618eav
  text: |-
    ### finish iteration 1 — done
    - implement: changed (EventProjection.swift new; PromptTurn.swift refactored; EventProjectionTests.swift + ProjectionTestSupport.swift new; PromptTurnTests.swift updated)
    - test: green (swift test — 197 tests in 20 suites, 0 failed, 0 skipped, zero compiler warnings)
    - commit: 0d5a878
    - review: clean (review sha HEAD~1..HEAD — 0 findings; task moved to done)
  timestamp: 2026-09-02T02:11:26.676148+00:00
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: done
position_ordinal: '8e80'
title: 'Event projection: Router SessionEvent to session/update, tool_call_update, usage'
---
## What
Plan.md §8.4–§8.5, §11.6. Create `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift` — the one mapping from Router's event stream to the wire.

**Router's `SessionEvent` has THIRTEEN cases, not seven.** Map all of them:

| `SessionEvent` case | Wire result |
|---|---|
| `turnStarted(TurnStart)` | `state_update: running` |
| `textDelta(String)` | `agent_message_chunk` |
| `textReset` | discard the text collected so far — see the note below |
| `reasoningDelta(String)` | `agent_thought_chunk` |
| `toolCall(id:name:argumentsJSON:)` | `tool_call_update` (creation) |
| `toolStatus(id:status:summary:output:)` | `tool_call_update` |
| `toolInvocation(ToolInvocationRecord)` | correlation record only, not a wire message |
| `entryRecorded(id:kind:)` | no wire message; use it to close a message |
| `compaction(CompactionResult)` | `usage_update` only |
| `discoveryPrimingFailed(_)` | log only |
| `generationStalled(GenerationStall)` | log only; it is a report, not a bound |
| `runSettled(OperationEvent)` | the terminal `tool_call_update` status |
| `turnEnded(TokenUsage)` | `usage_update` only — **never `idle`** |

**The enum has no library evolution.** Upstream tells a consumer to write a `default` arm. Write one.

**One wire update has no `SessionEvent` source: `tool_call_content_chunk`** (plan.md §8.4, §11.6, §11.8; decided 2026-09-01). The spec says it appends one `ToolCallContent` item, and a later `tool_call_update` with `content` replaces the whole array. The live source is the host-owned `ShellOutputChunkStream` that the catalog passes to `withShell(outputChunkStream:)`. Consume it in the projection: each `ShellOutputEvent` whose kind is `.output(stream:bytes:)` becomes one `tool_call_content_chunk` with a text `content` item (decode the bytes as UTF-8 with replacement; never drop bytes silently), keyed by `commandID`, which is the run's `completionToken` and the `toolCallId`. A gap event becomes one chunk that says bytes were dropped. At settlement (`runSettled`), the `tool_call_update` carries the complete `content` from the stored record; that replace is the convergence step. The wire type is `ToolCallContentChunk { toolCallId, content: ToolCallContent, meta }`.

**`textReset` is load-bearing.** It means "discard the text collected so far". Send a whole-message upsert with `content: [X]` to replace what the client accumulated. Do not send another `*_chunk`. This is §8.3's replace row.

**Terminal status comes from `runSettled(OperationEvent)`:**
- Router's own `ToolCallStatus` has only `running`, `completed` and `failed`. Router derives it from the SDK transcript diff. It is not rich enough for the wire.
- `OperationEvent` carries `tool`, `op`, `correlationID`, `kind`, `detail`, `outcome` and `elicitation`. `OperationEventKind` is `progress`, `completed` or `elicitation`.
- **`OperationOutcome` lives in `FoundationModelsExtras`**, not Router. Router re-exports it. Cases: `succeeded`, `failed`, `timedOut`, `stopped`, `cancelled`, `lost`, `other(String)`. `timedOut` is camelCase in Swift; its wire string is `timed_out`.

**Read the envelope defensively.** The rule "outcome is non-nil if and only if `kind == .completed`" is a doc comment, not a type guarantee. The only initializer is a plain memberwise init with `outcome` defaulted to nil, there is no precondition or validating factory, and `Codable` is synthesized so a decode does not check it either. So a `.completed` event can arrive with a nil outcome, and a `.progress` event can arrive carrying one. Handle both without crashing: treat a terminal event with no outcome as unknown, and ignore an outcome on a non-terminal event.

Write the one total function `OperationOutcome -> ToolCallStatus`:
`succeeded`→`completed`; `failed`→`failed`; `timedOut`→`failed` (name the timeout in the text); `stopped`→`cancelled`; `cancelled`→`cancelled`; `lost`→`_lost`; `other(raw)`→ the raw value under the `_` rule.

Obey these upstream semantics:
- `.stopped` is an authoritative kill. The work is certainly dead.
- `.cancelled` is a request only. The work can continue.
- `.lost` is unknowable. **Never flatten `.lost` into `.failed`.** Its text says "we do not know if this ran".

**Router holds no such mapping. We own it.** A survey found no `OperationOutcome -> ToolCallStatus` function anywhere in Router; the two type sets are disjoint.

Other facts to obey:
- `toolCallId` is Apple's `Transcript.ToolCall.id`, passed through unchanged. It arrives on `toolCall` and `toolStatus`. Do NOT use `ToolInvocationRecord.correlationID` for it — that is the run's `completionToken`, a different identity space.
- v2 has no create variant. The first update with an unseen `toolCallId` is the creation and should carry `title`. `pending` is the default when a creating update omits status. A running call must say `in_progress`.
- **`turnEnded` fires once per inner generate call.** A turn that retries after a recovered overflow sends one `turnStarted` and TWO `turnEnded`. **Sum the usage across every `turnEnded` in the turn, then report it one time.** Never send `idle` from this event; `idle` comes from the completion of our own turn task.
- Event order inside a turn: `turnStarted` → a proactive `compaction` if one fires → `textDelta` fragments → the turn's tool and reasoning events and one `entryRecorded` per recorded entry → `turnEnded`. A **proactive** fold's `compaction` arrives AFTER `turnStarted`, not before the turn. A **reactive** fold's arrives after the failed attempt's `turnEnded`.
- `TokenUsage` is `{tokensIn, tokensOut, contextFill}`. There is no cost field. **`contextFill` can be `Double.nan`** when no stamp exists, and the constant naming it is internal. Test `.isNaN` yourself and omit the field rather than send NaN.
- The diff mapping trap (§11.6): for `move` and `copy`, map the files capability's `FileChange.path → oldPath` and `destinationPath → path`. For `add`, `delete` and `modify`, map `path → path`. Take `rawInput`/`rawOutput` from the structured per-call record, never the rendered string.
- Compaction (§8.5) sends `usage_update` only. The meter drops. No message update clears or rewrites anything.

- [ ] All thirteen cases mapped, plus a `default` arm
- [ ] `textReset` sends a whole-message replace
- [ ] Upsert-as-create tool_call handling with title on first
- [ ] The total `OperationOutcome → ToolCallStatus` function, driven by `runSettled`
- [ ] Defensive envelope reads for the unenforced outcome rule
- [ ] Usage summed across every `turnEnded`, reported once, and no `idle` from the event
- [ ] NaN `contextFill` guarded
- [ ] move/copy path-direction mapping

## Acceptance Criteria
- [ ] A scripted tool turn yields create (title, `in_progress`) → `completed`, with one stable `toolCallId` across the updates
- [ ] Every `OperationOutcome` case maps per the table; `other(raw)` passes through under the `_` rule
- [ ] A scripted `.lost` outcome reports `_lost` and never `failed`
- [ ] A `.completed` event with a nil outcome, and a `.progress` event carrying one, are both handled without a crash
- [ ] A scripted `textReset` produces a whole-message replace, not a chunk
- [ ] A scripted retry turn sends two `turnEnded`, produces one summed `usage_update`, and produces no `idle` from the projection
- [ ] A NaN `contextFill` omits the field and does not serialize NaN
- [ ] A scripted move reports `oldPath` = source and `path` = destination
- [ ] A scripted proactive compaction arrives after `turnStarted`, and yields one `usage_update` and zero message updates

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift` — harness-driven scripted turns, plus one raw-JSON shape assertion through the transport
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.