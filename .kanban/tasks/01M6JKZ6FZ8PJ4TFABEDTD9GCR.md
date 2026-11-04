---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6jqb1ep5hvfb9jetpt0wayw
  text: 'Implemented on branch wt-slot (one commit, not pushed). A slot switch now suspends, closes, and restores with switchingModel: true under the same id. Open gaps: (1) a running child run is still cancelled by the switch, as before; only a recorded child stays in the tree. A live child needs claimingRuns and re-drive (SessionResumeNested). (2) No Router fork API is reachable, so a fork has no test. (3) Restore keeps the recorded budget limit, so a smaller context needs compact() once but the limit stays unscaled. The review tool has not run.'
  timestamp: 2026-11-04T07:28:25.046593+00:00
- actor: claude-code
  id: 01m6kgdnxht8sm0dbxvrhp6a2y
  text: |-
    ### review of commit 28571d0 — findings (not recorded in the description)
    - evidence: review sha 28571d0~1..28571d0. 2 findings (2 confirmed, 5 refuted). 21 pairs attempted, 0 failed.
    - [ ] Sources/FoundationModelsACPAgent/Agent/ModelSlotSwitch.swift:175 swift/doc-parameter-naming: The doc entry for the parameter of install(_:in:slot:replacing:) is named replacingId. That name matches neither the internal name id nor the external label replacing, so DocC cannot resolve it against the declaration. Change the doc key on line 175 to `///   - id:`. Keep the prose that describes the session root of the restore.
    - [ ] Tests/FoundationModelsACPAgentTests/ModelSlotSwitchSessionIdTests.swift:48 reuse/reuse: The new helper switchToFlash repeats the body of switchModelSlot in HookCompositionTests. The copy does not drain the hook dispatcher, so the two helpers can diverge. Keep one helper for the slot switch. Move the slot-switch helper to the shared test support (for example ScriptedPromptFixture) as one internal function. Let it take a flag or a second step for the dispatcher drain. Use it from both HookCompositionTests and ModelSlotSwitchSessionIdTests, and delete the private copies.
    - next: the peer session fixes both findings.
  timestamp: 2026-11-04T14:46:45.937330+00:00
position_column: done
position_ordinal: ffffaa80
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