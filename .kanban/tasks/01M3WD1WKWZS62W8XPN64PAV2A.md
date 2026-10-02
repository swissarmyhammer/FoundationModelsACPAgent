---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The turn ends while a backgrounded runCode is in flight, so its result never reaches the model
---
## Problem

A `runCode` snippet that does not settle in the inline wait gives `pending: true` and tells the model: "End your answer now. When the snippet finishes, its result comes back to you as a new message." The model obeys. But the agent ends the ACP turn with `end_turn` when Router's caller stream ends, and the caller stream ends while a background run is in flight (Router contract, `RoutedSession.swift:227-231`). The result comes as a mail-delivery answer that no caller waits for (`RoutedSessionActorPump.swift:91-96`, `answerMail`), and its events go only to `streamSessionEvents()`. The agent never reads that stream. The client then sees `end_turn`, and a SWE-bench client closes the session; close cancels the runs (`RoutedSessionActorDrain.swift` `sweepBackgroundRuns`).

Evidence: SWE-bench run of 2026-10-01, `django__django-14608`, `bench/preds.code-context.transcripts/django__django-14608/`. The model loaded `explore`, made 4 `grepCode` calls, then two snippets went pending. Its last answer: "Waiting for the pending searches to complete." The turn ended `end_turn` after 168 s with an empty patch. The last two tool outputs are `outcome: cancelled`, `detail: ""` (the close cancelled them).

## Cause

`PromptExecution.drive` (PromptExecution.swift:235-339) reads only `session.streamEvents(to:maxTokens:)` and maps its end to `.endTurn`. It does not check for runs in flight, and `EventProjection.swift:323` ignores `.answered` and `.mailDeliveryPaused`. Task 01M3Q37P7P8A9BPHX4KGNM93YE recorded this cause for a close hang, and did not fix the turn end.

## What to do

- Subscribe to `streamSessionEvents()` before `streamEvents` starts, for the time of the prompt.
- When the caller stream ends and a run of the session is in flight, do not send the stop reason yet.
- Project the session events (`runSettled`, and the deltas and tool calls of the mail-delivery answer) into the same ACP turn, as the caller events are.
- End the turn when no run is in flight and the mail-delivery answer ended (`answered` or `answerFailed`), or when mail delivery paused (`mailDeliveryPaused`). Map the stop reason from the last answer, as now.
- `session/cancel` must still end the wait at once.
- If Router has no public read for "runs in flight", ask the Router session for one; do not copy Router state in the agent.

## Tests

- Scripted: a snippet goes pending, the model ends its answer, the run settles, the mail answer runs: the client gets the mail answer's updates in the same turn, and the stop reason comes after them.
- `session/cancel` during the wait ends the turn with `cancelled`, and no update follows.
- A turn with no background run ends as now.
- The tests of task 01M3A30WN7D2CB2X7EGM0K2VN6 that expect `end_turn` while a background run waits: change them to the new contract. #bench