---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
title: 'session/resume gives the current mail delivery pause: re-send it when paused, never when lifted'
---
## What
Request from testudoapp-75 (2026-11-10). FoundationModelsACPClient 8d9c81b sets `mailDeliveryPause` to nil after a `session/resume` replay with history. The pause comes back only if the agent sends `_mail_delivery_paused` again in the replay.

Research (2026-11-10):
- The agent sends `_mail_delivery_paused` only from the live event stream: `ACPEventTranslator.swift` ~421-427 (`case .mailDeliveryPaused`, `MailDeliveryPauseReport.update(for:)`).
- `SessionMergeEngine` (FoundationModelsACP, `Session/SessionMergeEngine.swift` ~166) keeps an `.unknown` update as a transcript entry. `SessionHistory.replayUpdates(from:)` replays the transcript entries. Thus a recorded pause is probably replayed, but as a PAST entry: the replay also re-sends a pause that a later client message already lifted.
- `syncCurrentState` (`SessionResume.swift` ~574) sends the current state and the session info, but no current pause state.

1. Confirm with tests what the hot resume and the cold restore send today.
2. Treat the pause as current state, as `state_update` is: leave `_mail_delivery_paused` out of the replay (`SessionHistory.replayUpdates`, the same way as the retained `state_update`), and send it after the replay in `syncCurrentState` only when the session is paused now. Read "paused now" from Router (the `MailDeliveryPause` state of the session) or keep it in the session entry: set it at `.mailDeliveryPaused`, clear it when the pause is lifted (the next client prompt, or the Router event that lifts it).
3. The cold restore must give the same result. If Router does not restore the pause state, record that and send no pause.

## Acceptance Criteria
- [ ] A hot resume of a paused session sends one `_mail_delivery_paused` after the replay, with the current counts.
- [ ] A hot resume of a session whose pause was lifted sends no `_mail_delivery_paused`.
- [ ] The replay itself has no `_mail_delivery_paused`.
- [ ] The cold restore follows the same rule, or the card records why it cannot.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/HotResumeTests.swift` (or a new `MailPauseResumeTests.swift`): paused, then resume, gives one pause after the replay; paused, then lifted by a prompt, then resume, gives no pause.
- [ ] A cold restore test for the same two cases.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1