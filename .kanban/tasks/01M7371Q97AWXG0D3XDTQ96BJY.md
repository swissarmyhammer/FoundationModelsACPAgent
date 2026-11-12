---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73sf3ygy19x4xz9p6ed5jk4
  text: |-
    Research (implement step):
    - `SessionMergeEngine.apply` keeps `.unknown("_mail_delivery_paused")` as a transcript entry. `replayUpdates(from:)` sends `transcriptUpdates`, thus today each replay (hot and cold) sends each recorded pause again, also a pause that a later prompt lifted.
    - `syncCurrentState` sends no pause.
    - Router has no public read of the pause state. `mailOnlyAnswersInARow` is a private counter of the live Router session.
    - Cold restore: Router does not restore the pause. `SessionTreeRestoration` gives each queued mail with no terminal record the terminal event `lost` (`reportLostMail`), and the mail does not go back to the queue. The restored session starts with `mailOnlyAnswersInARow = 0`. Thus a restored session holds no mail and is not paused. The cold restore must send no pause.
    - An action command (`CommandDispatch`, `.action`) inserts a user message but sends no mail to Router. Thus "a user message after the pause" is not a correct lift test. The lift is a model prompt (`scheduleModelPrompt`), which mails the prompt to Router.
    - Plan: keep the pause in force in the session entry (`ActiveSession.mailDeliveryPause`). Set it in `recordInHistory` in the same actor step as the history record. Clear it in `scheduleModelPrompt`. The hot resume reads it in the step of the take, as it copies the tree, so a pause after the take goes live through the hold and is not sent two times. The replay leaves out each `_mail_delivery_paused` entry.
    - The client (FoundationModelsACPClient `MailDeliveryPauseExtension`) clears the pause at the start of a replay with history and at each user message. Thus a pause that the sync sends before the response stays at the client.
  timestamp: 2026-11-10T22:32:41.168765+00:00
position_column: doing
position_ordinal: '8180'
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