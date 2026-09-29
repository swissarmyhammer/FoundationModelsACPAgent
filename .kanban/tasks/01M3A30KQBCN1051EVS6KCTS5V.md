---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q1xc21qbh42a9ywqw87r7z
  text: |-
    A finding from ^m0k2vn6 that is in the area of this card (close of a session whose work waits for the model queue).

    Setup: two sessions on one queued scripted model, each in its own working directory. The script is one `runCode` with `tools.shell.execute({ command: "cat release.fifo && rm release.fifo" })`. A's cwd held a named pipe, B's cwd a plain file. B's shell run settled at once and its mail started mail-only answers. Each answer replayed the script, so B looped until `mailOnlyAnswerLimit` (100). The test then wrote A's pipe, so A's shell run settled and A had mail that waited for the queue.

    Observation: `session/close` for A did not return in 60 s. It did not return after B's mail delivery paused either. A's mail answer never got a pass (the log shows no second `runCode` for A).

    I did not find the cause. Examine whether Router `close()`/`drain()` can wait for ever on a session whose mail-started answer waits for a queue place. The cancel/close tests of this card are the place to prove it or to rule it out.
  timestamp: 2026-09-29T17:03:03.745542+00:00
- actor: claude-code
  id: 01m3q2v7yt8s93g6g5f4hdftqw
  text: |-
    Research done. The card text is older than the code. The current API: Router has no turns. `cancelCurrentTurn()` and `.noTurnInFlight` are gone. Read the card as follows:
    - "the turn-long Router gate" = the generation queue of the pool entry.
    - `cancelCurrentTurn()` = `RoutedSession.cancel() -> CancellationResult` (`.requested` / `.nothingToCancel`). The Router doc says: a submission that waits for the worker of the generation queue is removed from the queue at once.
    - Commit 4ac665b already changed `sessionCancel(_:)` (PromptTurn.swift) and `tearDownSession` (SessionLifecycle.swift) to `session.cancel()`.
    - Step 1 (`swift package update`) is done: the Router dependency already has the new API.
    - The test support has `QueuedScriptedFixture` (two sessions on one pool entry) and `.holdUntilReleased(ScriptedHold)`. The tests use them.
  timestamp: 2026-09-29T17:19:22.586490+00:00
- actor: claude-code
  id: 01m3q380gc80k5s191abrn3vxm
  text: |-
    Implementation landed. No production code changed. The Router cancel already reaches a request that waits for a queue place.

    - Tests: `cancelEndsARequestThatWaitsForTheModelQueue` and `closeEndsARequestThatWaitsForTheModelQueue` in CancellationTests.swift. They use `QueuedScriptedFixture` and `.holdUntilReleased`. A holds its pass. B's prompt waits for a queue place (the test sees `waitingCount == 1`). Cancel or close of B gives B `idle(cancelled)` while A has no idle yet. Then the hold is released, A ends `end_turn`, and (for the cancel test) a second prompt on B ends `end_turn`.
    - The first run passed. To prove that the cancel test can fail, I changed `sessionCancel(_:)` for one run to skip `entry.session.cancel()`. The test failed: Poll timed out on "idle update 1 of B", and the stop reason was nil. I restored the call.
    - `QueuedScriptedFixture.waitForIdle(of:count:)` got a `count` parameter (default 1), for the second prompt on B.
    - Doc changes: the doc comment of `sessionCancel(_:)`, and plan.md §8.6. The table row is now "the prompt in flight, also a request that waits for a place in the model queue | `RoutedSession.cancel()` | `.requested` / `.nothingToCancel`". The paragraph under the table names `cancel()`, and a new paragraph states that the cancel reaches a queued request.
    - plan.md still names `cancelCurrentTurn()` in the dependency table near the end of the file. I did not change it: card ^33agh (the plan.md prose rewrite) owns that text.

    The close hang in the first comment: the close test shows that a close of a session whose CALLER prompt waits for a queue place answers at once (about 0.6 s). The observation of ^m0k2vn6 was a different shape: an answer that the MAIL of a settled shell run starts, with B in a loop to `mailOnlyAnswerLimit`. These tests do not build that shape. I recorded it as a new task ^gnm93ye with the reproduction steps.

    Test counts: `swift test --filter CancellationTests` passed 8 of 8 tests. `swift test` passed 613 tests in 70 suites (611 + 2 new). The one known issue is the old deliberate `withKnownIssue` in HarnessSmokeTests. The compiler gave no warnings. The only warning is the build-system line "missing creator for mutated node" for the mlx bundle, which was there before this change.
  timestamp: 2026-09-29T17:26:20.940551+00:00
- actor: claude-code
  id: 01m3q382pgn4jt06yy357j0t66
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/CancellationTests.swift, Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift, Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift (doc comment only), plan.md (§8.6). `swift test --filter CancellationTests`: 8/8 passed. `swift test`: 613 tests in 70 suites passed, 0 compiler warnings.
    - next: /review. Follow-up task ^gnm93ye covers the mail-started close case.
  timestamp: 2026-09-29T17:26:23.184181+00:00
- actor: claude-code
  id: 01m3q38bn9tj9sg3tg7sdzxp7y
  text: 'Correction to the "Implementation landed" comment: the card that owns the remaining `cancelCurrentTurn()` text in the plan.md dependency table is ^wqe0awe (the plan.md prose rewrite), not "^33agh". That card also names `cancelCurrentRequest()` for §8.6. The Router API is `cancel()`, so its text is now old too. The §8.6 row of this card already uses `cancel()`.'
  timestamp: 2026-09-29T17:26:32.361947+00:00
depends_on:
- 01M3A37J8X6VKD5BKYWSJ4HCZD
position_column: doing
position_ordinal: '8180'
title: Prove that session/cancel and session/close end a request that waits for a place in the model queue
---
## Why

Now a request that waits for the turn-long Router gate can get `.noTurnInFlight` from `cancelCurrentTurn()`. The Router task "Stop holding the generation gate for the whole turn" (FoundationModelsRouter card `01M39ZNSNZGBYEY5G8R93KJN94`) changes this: the request id exists before the queue wait, and the cancel reaches the wait (`waitUnlessCancelled`). This agent must show that the new contract gives the ACP terminator `idle(cancelled)` at once.

Note (2026-09-29): the Router API changed after this card was written. Router has no turns now. `cancelCurrentTurn()` and `.noTurnInFlight` are gone. The API is `RoutedSession.cancel() -> CancellationResult` (`.requested` / `.nothingToCancel`), `cancel(message:)`, and `drain() async -> Bool`. Commit 4ac665b changed `sessionCancel(_:)` and `tearDownSession` to `session.cancel()`.

Callers in this repository:
- `RoutedACPAgent.sessionCancel(_:)` (`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`).
- `tearDownSession(_:entry:)` (`Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift`), which waits for the terminator before the close response.

## External dependency

Router card `01M39ZNSNZGBYEY5G8R93KJN94` on Router `main`. Do not start before it lands.

## What

1. `swift package update FoundationModelsRouter`.
2. Add tests with two sessions on one scripted model (one pool entry). Session A holds a pass open (a scripted model that waits on a continuation). Session B sends a prompt, and its request waits for a queue place.
3. Change code only if a test fails. Update the comments in `sessionCancel(_:)` and in plan.md §8.6 (the table row for "the prompt in flight": a request that waits for the model queue is in flight, and the cancel reaches it).

## Acceptance Criteria

- [x] `session/cancel` for B, while B waits for a queue place, gives `idle` with `stopReason: cancelled` before A releases its pass.
- [x] `session/close` for B in the same state answers after B's `idle(cancelled)`, and before A releases its pass.
- [x] After the cancel, A completes its prompt, and a new prompt on B completes (the queue place is not lost).

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/CancellationTests.swift`: `cancelEndsARequestThatWaitsForTheModelQueue`, `closeEndsARequestThatWaitsForTheModelQueue`. Use a timeout so that a regression fails and does not hang.
- [x] Run `swift test --filter CancellationTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue