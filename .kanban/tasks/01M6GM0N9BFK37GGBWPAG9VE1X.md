---
depends_on:
- 01M6GPCJ3CMS7YE71DQ3J33QC8
position_column: todo
position_ordinal: 8c80
title: Resume sends the current-state sync (state_update snapshot, session info) after any replay and before the response, also without replayFrom
---
## What
ACP v2 `session/resume` has a fixed order (v2 Session Setup, "Ordering"): (1) replay the requested history, if any; (2) for each item of the `background` list that the replay did not deliver at its current state, send a current `terminal_update`, `tool_call_update` or `subagent_update` (see the background list task); (3) send a CURRENT `state_update` ("MUST send a current state_update after any requested history replay and before the resume response", also when no replay was requested); (4) send current session info with `session_info_update`, and optionally a current `usage_update`; (5) send the response, which carries the current `configOptions` and `availableCommands`. The client must not reset the state to idle when the response arrives. The agent must not send a current update for an entity that the replay already covered at its current state.

Today (read in the code, not run):
- `replayHistory` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (near line 471) returns at once when there is no cursor. A resume with no `replayFrom` sends no sync.
- With a cursor, `replayUpdates(from: .start)` (`Agent/SessionHistory.swift`, near line 150) sends `transcriptUpdates + stateUpdates`. `stateUpdates` (FoundationModelsACP `Session/SessionMergeEngine.swift`, near line 257) includes `agentState`, the RETAINED last `state_update`. Historical state updates must not be replayed as current activity.
- `SessionStateLedger` (`Agent/PromptState.swift`, near line 48) sends only changes. It cannot give its current state on demand.

Do:
1. Add `SessionStateLedger.currentSnapshot()`: `running`, `requires_action` (a prompt or a request waits for the user), or `idle` (the last stop reason for context only). It uses the same actor and sink as the changes, so a snapshot never overtakes a newer change.
2. In the resume path send the snapshot and `session_info_update` after the replay (or at once when there is none), then the response. Keep the retained `agentState` out of the replay path.
3. The sync runs for every resume, with or without `replayFrom`. Without `replayFrom` the agent sends no history.
4. An idle snapshot announces no new completion or cancellation.
5. Do not change FoundationModelsACP or the client from this task. The `background` items of step (2) are added by the background list task.

## Acceptance Criteria
- [ ] With `replayFrom: start` the wire order is: replay, then one current `state_update`, then `session_info_update`, then the response.
- [ ] With no `replayFrom` there is no history, and the current `state_update` and `session_info_update` still come before the response.
- [ ] The snapshot shows `running` when a prompt is open at the resume, and `idle` otherwise; a recorded old `running` is never sent as current.
- [ ] No retained `state_update` is in the replay.
- [ ] A snapshot never overtakes a newer state change.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ResumeSyncTests.swift`: order with and without a cursor, running and idle snapshots, no retained state in the replay, ordering under a concurrent change.
- [ ] Run `swift test --filter ResumeSyncTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.