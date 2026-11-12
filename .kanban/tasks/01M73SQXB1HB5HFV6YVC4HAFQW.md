---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
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