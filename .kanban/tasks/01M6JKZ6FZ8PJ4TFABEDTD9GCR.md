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
- actor: claude-code
  id: 01m6khnbhjhnbc0wbd34ehe5jk
  text: |-
    ### review — findings
    - evidence: `review sha 28571d0~1..efabcd0`, 4 findings (4 confirmed, 8 refuted): BuiltinCommands.swift:123, SubagentMessageWireTests.swift:145, SubagentMessageWireTests.swift:254, ScriptedPromptFixture.swift:379. The 2 earlier findings (ModelSlotSwitch.swift:175, ModelSlotSwitchSessionIdTests.swift:48) do not return. The finding at ScriptedPromptFixture.swift:379 is the same cause as the second earlier finding, and the duplicate helper in HookCompositionTests still exists.
    - note: the range also holds commit e4566e8 (task ^nwsamy7). The two findings in SubagentMessageWireTests.swift come from that commit.
    - next: the implementer fixes the 4 findings. The task is back in review.
  timestamp: 2026-11-04T15:08:26.034199+00:00
position_column: review
position_ordinal: '8180'
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

## Review Findings (2026-11-04 08:58)

> Scope: `review sha 28571d0~1..efabcd0` — reviewed the diffs only — lines this change added or modified. 33 file(s) reviewed, 0 not reviewed.

- [ ] `Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift:123` `completeness/public-output-contract` — `replaceSession` returns without any effect when the binding or its registry is missing. The restored session is then never installed, and no warning or log line says so. `/compact` and `/context` keep acting on the old session after a model slot switch. Log a warning, or make the function return a Bool, when the swap cannot happen. Add a test that calls `replaceSession` before `bind` and checks that the outcome is visible.
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentMessageWireTests.swift:145` `test-integrity/no-test-cheating` — The assertion passes when the child's final view and the caller's incoming final view are both missing. Both sides are nil, so the comparison is true. The test does not prove that the final message was linked to its incoming view. Use `try #require` for `final` and `incoming`. Then assert `final.recipientMessageId == .value(incoming.messageId)`.
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentMessageWireTests.swift:254` `test-integrity/no-test-cheating` — The assertion passes when the child's incoming view and the root session's outgoing view are both missing. The test does not prove that the child received the root's send with a matching message id. Unwrap `incoming` and `outgoing` with `try #require(...)` before the comparison. Then assert `incoming.senderMessageId == .value(outgoing.messageId)`.
- [ ] `Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:379` `reuse/reuse` — The new `switchModelSlot` helper repeats the slot switch that already exists in `HookCompositionTests`. Two copies of the same `session/set_config_option` call can drift apart. A change to one copy can leave the other wrong. Make `HookCompositionTests::switchModelSlot` call `ScriptedPromptFixture.switchModelSlot`, or remove its copy and use the shared helper at each call site. If the contracts differ, parameterize the shared helper instead of keeping a parallel copy.
