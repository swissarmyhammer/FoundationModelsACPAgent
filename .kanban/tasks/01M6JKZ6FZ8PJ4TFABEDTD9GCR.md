---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: 'A model slot switch keeps the session id: suspend, then restore on the new slot'
---
## What
Today a model slot switch replaces the Router session with a new one that has a new id, over the same surface. The ACP id stays. So `ToolContext.sessionID` differs from the client session id after a switch, the recording of one ACP session is split over two Router sessions, and `ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID` fails (the shell owner now comes from `ToolContext`).

The user expects the two ids to be the same: an ACP session is backed by a Router session.

## Router (pushed, 6331c9c3)
- `RoutedModel.restoreSession(id:..., transcriptReader:, switchingModel: Bool = false)`. Call it on the `RoutedModel` of the NEW slot, after the old session is suspended.
- With the flag, the root and every recorded fork restore onto the new model. Each moved node appends one `modelChanged` event. The id, the folder and the lineage stay. No ended marker.
- Restore runs no compaction and does not scale the budget. A smaller context shows in `contextMismatches`, so the agent calls `compact()` itself.
- `TranscriptEvent.Kind.modelChanged` is a new case. Add it to each exhaustive switch.

## Plan
- Find the slot switch in `Agent/SessionSetup.swift` and `Agent/ConfigOptions.swift`. Suspend the old session, restore with `switchingModel: true` under the same id, and swap the object reference in the session entry.
- Remove the workarounds that the id split made necessary: `SnapshotSessionKeys.recordReplacement` (Agent/AgentHooks.swift) and the shell owner bind in `SessionSetup.swift`. Keep only what still has a reason. No shim.
- Handle the context: if `contextMismatches` shows a smaller context, call `compact()`.
- The host transcript reader (card ^zgqxj7z) then reads one folder per ACP session.

## Acceptance Criteria
- [ ] After a model slot switch, `ToolContext.sessionID` equals the ACP session id.
- [ ] `ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID` passes with the assertion that the ids are equal.
- [ ] One recording folder per ACP session after a switch, with a `modelChanged` event.
- [ ] A switch during a running prompt behaves as before (cancel or refuse; keep the existing rule).
- [ ] No Router session with the old id stays live.

## Tests
- [ ] Switch keeps the id; shell owner, transcript reader and `ToolContext.sessionID` agree.
- [ ] Switch to a smaller context runs `compact()`.
- [ ] Fork and child sessions survive a switch.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd`. Start after card ^zgqxj7z is merged to main: both change SessionSetup.swift. #transcripts