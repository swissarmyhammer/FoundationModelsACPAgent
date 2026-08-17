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
Plan.md §8.4–§8.5, §11.6. Create `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift` — the one mapping from Router's event stream to the wire:

- The §8.4 table: `textDelta` → `agent_message_chunk` (with the agent `messageId`); `reasoningDelta` → `agent_thought_chunk`; `toolCall` / `toolStatus` → `tool_call_update` (v2 has NO create variant — the first update with an unseen `toolCallId` is the creation and SHOULD carry `title`; `running` → `in_progress`); `turnEnded` → `usage_update`; turn boundaries → `state_update`. Discriminators are `snake_case`, properties `camelCase` — assert this in tests.
- `toolCallId` is Apple's `Transcript.ToolCall.id` passed through unchanged (the one identity, §1).
- Status vocabulary: `pending` default when a creating update omits status; a running call must say `in_progress`. **Terminal status derives from `OperationEvent.outcome` via the ONE total `OperationOutcome → ToolCallStatus` mapping in §8.4** — `succeeded`→`completed`, `failed`→`failed`, `timed_out`→`failed` (timeout named in the text), `stopped`→`cancelled` (authoritative), `cancelled`→`cancelled` (advisory), `lost`→`_lost`, unknown→raw value under the `_` rule — written once for every event-posting capability, never per-capability `detail` parsing (the vocabulary lives in Router's `Hosting/` substrate — `1ad4ydw` landed, and the Multitool consolidation moves it out of the removed OperationTool into Router; the shell capability `jt19xwc` and the mcp capability `zfp4a3j` emit it; §21). `_lost` carries "we do not know if this ran" in the text — never flattened to `failed` (§8.4, §11.5).
- The diff mapping trap (§11.6): for `move`/`copy`, map the files capability's `FileChange.path → oldPath` and `destinationPath → path`; for `add`/`delete`/`modify`, `path → path` unchanged. Fill `fileType`/`mimeType` where known; `ToolCallLocation` gets `line` when `GrepMatch` supplies it. `rawInput`/`rawOutput` from the structured per-call record, not the model-facing rendered string.
- Compaction (§8.5): `compaction(CompactionResult)` → **`usage_update` only** — the meter drops; no message upsert clears or rewrites anything; the fold summary stays in the journal.

- [ ] The §8.4 event table
- [ ] Upsert-as-create tool_call handling with title-on-first
- [ ] The total `OperationOutcome → ToolCallStatus` function (incl. `_lost`) + status defaults
- [ ] move/copy path-direction mapping
- [ ] Compaction → usage_update only

## Acceptance Criteria
- [ ] A scripted tool turn yields tool_call_update sequence: create (title, in_progress) → completed, with a stable toolCallId matching across updates
- [ ] Every `OperationOutcome` case maps per the §8.4 table; an unknown outcome value passes through under the `_` rule with generic rendering
- [ ] A scripted move operation reports `oldPath` = source and `path` = destination
- [ ] A scripted compaction yields exactly one usage_update with a smaller `used` and zero message updates
- [ ] Raw JSON of one update asserts snake_case discriminator + camelCase properties

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift` — harness-driven scripted turns; one raw-JSON shape assertion via the transport
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.