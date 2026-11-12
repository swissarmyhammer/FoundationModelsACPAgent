---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77r3y0hb4ke1fj4kf1a7zmp
  text: |-
    Research done.
    - The lift of a child pause: Router pauses only when an answer would start with no user-type mail (`RoutedSessionActorPump.runNextAnswer`). While the count is at the limit, each answer that runs has user-type mail. So each `SessionEvent.mailDelivered` of the session after a pause means that the pause lifted. The event comes on the same feed as `mailDeliveryPaused` (`streamSessionEvents()`), so the projector sees the two in Router order.
    - Plan: `ActiveSession.record(_:)` keeps the pause for each session (root and child). The projector calls a new lift hook at each `mailDelivered`; the agent clears `mailDeliveryPause` of that session. The root rule of ^tq96bjy (the prompt clears it) stays.
    - The child sync (`syncRestoredChild`) sends the pause in force through the snapshot sink of the child after `announceCurrentState()`. In a hot resume, that sink goes through the hold, so the pause comes after the state_update of the child. The child reads its pause when the sync runs (not at the take), as its state_update does: the live updates of the window go out before it, so the last pause on the stream is the pause in force.
    - A cold restore builds the child entry from the history file, not through `record(_:)`, so the child has no pause in force.
  timestamp: 2026-11-12T11:26:03.793802+00:00
- actor: claude-code
  id: 01m77s13bbp627fd41p2evp634
  text: |-
    Implementation landed.
    - `ActiveSession.record(_:)` keeps the pause in force for each session, root and child. The guard on `parentSessionId == nil` is gone.
    - New `RoutedACPAgent.liftMailDeliveryPause(of:)` clears the pause. `SessionProjector` takes a new `liftMailDeliveryPause` hook and calls it at each `mailDelivered` event. `SessionBuild` wires it for each session. The root prompt clear of ^tq96bjy now calls the same function.
    - `syncRestoredChild` sends the pause in force of the child after `announceCurrentState()`, through the snapshot sink of the child. In a hot resume, that sink goes through the hold, so the pause comes after the state_update of the child.
    - Tests (MailPauseResumeTests): the projector lift, a hot resume of a paused child (one pause, after the own state_update), a hot resume of a lifted child (no pause), and a cold restore of a paused child (no pause on the stream, no pause in force).
    - What did not work first: the fixture waited for an idle with a stop reason. A child sends `idle` with no stop reason, so the wait did not end. The fixture now waits for any `idle` of the child.
    - The tests record the pause through `recordInHistory(_:of:)`, the record path of a real pause. The hot lift test calls `liftMailDeliveryPause(of:)` directly. The projector test covers the `mailDelivered` wiring.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/{SessionSetup,SessionHistory,SessionProjector,SessionBuild,SessionResumeChildSync,PromptExecution,MailDeliveryPauseReport,ACPEventTranslator}.swift; Tests/FoundationModelsACPAgentTests/MailPauseResumeTests.swift; Tests/FoundationModelsACPAgentTests/Support/PausedChildTreeFixture.swift (new). `swift test`: 2004 tests in 220 suites passed, 0 failures, 0 compiler warnings (1 known issue that HarnessSmokeTests records on purpose, from before this change).
    - next: /review
  timestamp: 2026-11-12T11:41:59.531965+00:00
- actor: claude-code
  id: 01m77s58zcteqw8wm013wxbq3x
  text: |-
    ### review — clean
    - evidence: review sha 64cd038~1..64cd038 — 0 findings (0 confirmed, 1 refuted, 7 attempted, 0 failed); 10 files reviewed, 6 .kanban files ignored by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-11-12T11:44:16.364500+00:00
position_column: done
position_ordinal: ffffdb80
title: session/resume gives the current mail delivery pause of each live child session
---
## What
Found during ^tq96bjy. After ^tq96bjy, the replay of each session of the tree leaves out each recorded `_mail_delivery_paused` update (`SessionMergeEngine.replayUpdates(from:)`). The root session keeps its pause in force (`ActiveSession.mailDeliveryPause`), and a hot resume sends it after the replay. A nested (child) session keeps no pause: `ActiveSession.record(_:)` keeps the pause only for a root session, because a message of the caller, not a client prompt, lifts the pause of a child. Router counts the mail-only answers for each child session too ("A child session has a run plane of its own, and its own count").

Thus a hot resume of a tree with a paused child sends no pause for that child. Before ^tq96bjy, the replay of the child sent its recorded pause again.

1. Find the event that lifts the pause of a child: the delivery of user-type mail from the caller (`SessionEvent.mailDelivered`, or the `agents` message path).
2. Keep the pause in force of each child, set at the record of the pause, cleared at that lift.
3. Send it in the child sync after the response (`SessionResumeChildSync.swift`, after the `state_update` of the child), only when the child is paused now.

## Acceptance Criteria
- [ ] A hot resume of a tree with a paused child sends one `_mail_delivery_paused` on the stream of the child, after its snapshot.
- [ ] A child whose pause was lifted gets no pause.
- [ ] A cold restore sends no pause for a child (Router does not restore the pause).

## Tests
- [ ] A test in `Tests/FoundationModelsACPAgentTests/MailPauseResumeTests.swift` or `ResumeChildSyncTests.swift` for the two hot cases.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1