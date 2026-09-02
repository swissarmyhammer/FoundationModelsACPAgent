---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fyk345d6k38p27y3a2maer
  text: |-
    Research done. Findings:

    - Much of the cancel path landed with ^0svz8qf. `RoutedACPAgent.sessionCancel` calls `noteCancelRequested()` then `RoutedSession.cancelCurrentTurn()`, logs the result, and ignores an unknown id or an idle session. `PromptTurn.drive` catches `CancellationError` through `classify`, and reads `turnState.cancelRequested` after the stream ends, so a normal completion after a cancel also reports `cancelled`. The `idle` update is the last send of `drive` by construction.
    - Router source (`RoutedSessionActorGeneration.swift`): the `streamEvents` surface calls `Task.checkCancellation()` after the model stream ends. A cancellation that lands on the model call ALWAYS surfaces as a thrown `CancellationError` on our surface. The normal-completion ending occurs only when the cancel request is recorded after the model call completed. A wire-level scripted turn cannot make that race deterministic, so the ignore-cancellation test drives `PromptTurn.drive` with a synthetic stream that completes normally while `cancelRequested` is set.
    - `runSettled` carries only `.completed` operation events (`RoutedSessionActorRunJournal.swift`). A still-running detached call that we stop listening to settles with the advisory `.cancelled` outcome. Plan §8.4 table gives that outcome the text "we stopped listening". The current `EventProjection.cancelledNoteText` says "cancellation was requested; the work can continue" — this is the one production gap. Fix: change the note text.
    - Elicitation is not on this agent's surface yet, and the card's checklist has no elicitation item. `RoutedSession.close()` holds that duty upstream. No work here.

    Plan: add `Tests/Support/ScriptedTurnFixture.swift` (shared wire fixture, moved out of `PromptTurnTests` so `CancellationTests` does not copy it), add `CancellationTests.swift` (unknown-id no-op, idle-session no-op, strict idle-last order on a long-running turn, ignore-cancellation drive test, stopped-listening settlement text), change the note text in `EventProjection.swift`.
  timestamp: 2026-09-02T02:18:56.517760+00:00
- actor: claude-code
  id: 01m1fz0k7bwnxsy7yd006xhyqv
  text: |-
    Implementation landed, with TDD:

    - RED: `aCancelledRunSettlesAsCancelledAndSaysWeStoppedListening` in `EventProjectionTests.swift` failed on the old note text. All other new tests document behavior that landed with ^0svz8qf and pass.
    - GREEN: `EventProjection.cancelledNoteText` changed to "we stopped listening; the work can continue" (plan §8.4 table, §8.6).
    - New `Tests/.../CancellationTests.swift`: strict idle(cancelled)-last order on a long-running turn, the ignore-cancellation ending through `drive` with `cancelRequested` set (Router's `streamEvents` surface always throws when a cancel lands mid-call — see the research comment — so the normal-completion ending is only reachable as the recorded-request race, which the drive-level test makes deterministic), post-cancel tool updates before the idle, and the three no-op cancels (idle, unknown, closed).
    - New `Tests/.../Support/ScriptedTurnFixture.swift`: the wire fixture, waits, and readers moved out of `PromptTurnTests` so `CancellationTests` does not copy them. `PromptTurnTests` now delegates to it.
    - Elicitation answering on cancel: not on this agent's surface yet, and not in the card's checklist. `RoutedSession.close()` holds that duty upstream.

    `swift test`: 204 tests in 21 suites passed (1 known issue is the intentional `HarnessSmokeTests` self-check).

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/CancellationTests.swift, Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift
    - next: test
  timestamp: 2026-09-02T02:26:18.987216+00:00
- actor: claude-code
  id: 01m1fz1cd16edj83za7bqgffev
  text: |-
    ### test — green
    - evidence: swift test — 204 tests in 21 suites passed, 0 failed, 0 skipped; swift build shows no compiler warning (the one "missing creator" note is a pre-existing build-graph message from the mlx-swift dependency bundle, present before this change)
    - next: commit
  timestamp: 2026-09-02T02:26:44.769837+00:00
- actor: claude-code
  id: 01m1fz1zq82jb9nmydcbh6bkd5
  text: |-
    ### commit — changed
    - evidence: cafd91d feat(agent): confirm session/cancel with the strict idle(cancelled) terminator — 7 files, 468 insertions, 175 deletions
    - next: review
  timestamp: 2026-09-02T02:27:04.552041+00:00
- actor: claude-code
  id: 01m1fz9tpder8h7ay56s025dh6
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift:20 (code-hygiene/magic-numbers-swift). Subtask and acceptance boxes checked from the green run at cafd91d.
    - next: implement (name the milliseconds value of pollInterval)
  timestamp: 2026-09-02T02:31:21.549130+00:00
- actor: claude-code
  id: 01m1fza0cqad7pbkws5favc2w1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (5 source/test files; TDD with one RED on the stopped-listening text)
    - test: green (swift test — 204 tests, 21 suites, 0 failed, 0 skipped)
    - commit: cafd91d
    - review: findings (1 — ScriptedTurnFixture.swift:20, magic-numbers-swift)
  timestamp: 2026-09-02T02:31:27.383381+00:00
- actor: claude-code
  id: 01m1fzbe38np4gnybb96rq6j3c
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift. The poll-interval milliseconds value now rides the named constant `pollIntervalMilliseconds`, in the pattern of the harness cadence constant. Finding checkbox flipped.
    - next: test

    ### test — green
    - evidence: swift test — 204 tests in 21 suites passed, 0 failed, 0 skipped; no compiler warning
    - next: commit

    ### commit — changed
    - evidence: ee2b135 refactor(tests): name the poll-interval milliseconds in the shared fixture
    - next: review
  timestamp: 2026-09-02T02:32:14.184741+00:00
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: review
position_ordinal: '8180'
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

- [x] `cancelCurrentTurn()` called, and both results handled
- [x] Both endings handled: a `CancellationError` and a normal completion after cancel
- [x] Strict `idle(cancelled)` terminator ordering
- [x] Terminal tool statuses sent without holding the idle
- [x] Idle-session cancel is a no-op

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/cancel` is a notification, so there is no response. For an unknown or closed `sessionId`, log it and ignore it. Send no `state_update`.

## Acceptance Criteria
- [x] `session/cancel` with an unknown id produces a log line and no `session/update`
- [x] Cancelling a scripted long-running turn makes `idle(cancelled)` the last update, and no update of any kind arrives after it
- [x] A scripted turn that raises `CancellationError` reports `idle(cancelled)`, not a JSON-RPC error and not `refusal`
- [x] A scripted turn that IGNORES cancellation and returns a normal response still reports `idle(cancelled)` and does not report `end_turn`
- [x] Cancelling an idle session gives no error and no state change
- [x] A scripted detached call that is still running reports the "we stopped listening" text

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/CancellationTests.swift` — harness with a long-running scripted turn, a cancellation-ignoring scripted turn, and order assertions on the collector
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-01 21:27)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift:20` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
