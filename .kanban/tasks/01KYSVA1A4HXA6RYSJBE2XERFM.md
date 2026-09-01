---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kyyzmzkpvv98r3c4rwpvhrej
  text: 'Description updated by card 2p6913n (plan-only OperationOutcome mapping): the "Status vocabulary" bullet now derives terminal status from `OperationEvent.outcome` via the ONE total `OperationOutcome → ToolCallStatus` function of plan.md §8.4 (upstream: OperationTool `1ad4ydw`, Shelltool `jt19xwc`, MCP `zfp4a3j` — all landed, see §21). Added a matching subtask line and acceptance criterion for full-enum + unknown-value mapping. Structure otherwise unchanged.'
  timestamp: 2026-08-01T15:38:58.038179+00:00
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: todo
position_ordinal: 8c80
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