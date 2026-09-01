---
assignees:
- claude-code
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: todo
position_ordinal: 8d80
title: 'Cancellation: session/cancel confirmation semantics'
---
## What
Plan.md §8.6. Work in `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`, plus a small `Cancellation.swift` if that is cleaner.

**Router's cancellation is no longer queue-side only.** An earlier draft said an in-flight turn runs to completion until upstream work lands. That is wrong. `RoutedSession.cancelCurrentTurn()` cancels the Task that runs the model call, so cancellation does reach the tools the SDK invokes.

`session/cancel` is a notification. On receipt:

1. Call `RoutedSession.cancelCurrentTurn() async -> TurnCancellationResult`. The result is `.requested` or `.noTurnInFlight`.
2. Treat `.requested` honestly. It means the request was recorded, not that the model has stopped.
3. **Handle BOTH endings. Do not assume a throw.** Router's own contract says model work that never checks for cancellation runs to completion and the turn returns its response. So a cancelled turn either raises `CancellationError` or completes normally with a real answer. Catch and map `CancellationError` when it appears, and handle a normal completion after a cancel as well. `CancellationError` must never escape as a JSON-RPC error and never as `refusal`.
4. Send `state_update: idle` with `stopReason: "cancelled"` strictly last. Any post-cancel updates go out before the idle update. Send `cancelled` even when the turn completed normally, because the client asked to cancel.

Also note:
- Abandoning a `streamResponse` or `streamEvents` stream cancels the turn behind it. Do not drop a stream unless you mean to cancel.
- A stream keeps the fragments it already yielded.
- The transcript records a cancelled turn as a failed turn.
- Router's other two cancel paths stay separate. A background run cancels with `ToolContext.cancel(completionToken:) -> CancelOutcome`. A queued prompt cancels with `cancelPrompt(id:)`, but **that path is not reachable on our surface**: §7.1 refuses a second prompt as a client error and never queues one, so we never create a queued prompt.
- Propagation past a process boundary stays advisory. An in-flight MCP call cannot be forced to stop. The honest result is "we stopped listening". Say that in the tool-call text for a still-running detached call. A transport drop settles the run `.lost`, never `.failed`.
- Send correct terminal tool statuses where we have them, but never hold the idle update waiting for them.
- Cancel of an idle session is a no-op. `.noTurnInFlight` gives no error and no state change.

**The pending-permission hook is gone.** An earlier draft provided a hook that answered pending `session/request_permission` requests as cancelled. We no longer send permission requests. The equivalent duty now is elicitation: `RoutedSession.close()` rejects every pending elicitation on teardown, and a cancel answers a pending elicitation with the cancelled result.

- [ ] `cancelCurrentTurn()` called, and both results handled
- [ ] Both endings handled: a `CancellationError` and a normal completion after cancel
- [ ] Strict `idle(cancelled)` terminator ordering
- [ ] Terminal tool statuses sent without holding the idle
- [ ] Idle-session cancel is a no-op

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/cancel` is a notification, so there is no response. For an unknown or closed `sessionId`, log it and ignore it. Send no `state_update`.

## Acceptance Criteria
- [ ] `session/cancel` with an unknown id produces a log line and no `session/update`
- [ ] Cancelling a scripted long-running turn makes `idle(cancelled)` the last update, and no update of any kind arrives after it
- [ ] A scripted turn that raises `CancellationError` reports `idle(cancelled)`, not a JSON-RPC error and not `refusal`
- [ ] A scripted turn that IGNORES cancellation and returns a normal response still reports `idle(cancelled)` and does not report `end_turn`
- [ ] Cancelling an idle session gives no error and no state change
- [ ] A scripted detached call that is still running reports the "we stopped listening" text

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/CancellationTests.swift` — harness with a long-running scripted turn, a cancellation-ignoring scripted turn, and order assertions on the collector
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.