---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q4wcecn7qx891je8srfa10
  text: |-
    Research done.
    - The agent drives a prompt with `RoutedSession.streamEvents(to:maxTokens:)`. That stream ends while a background run is in flight. Thus a mail-started answer runs when the session has no `activeTurn`. `tearDownSession` then goes directly to `RoutedSession.close()`, which runs `drain()`: `cancel()` (hold the mail, `requestCancelOfRunningWork()`, which cancels `inFlightModelCall`), the sweep, `joinRunBodies()`, and a wait for `pumpTask`.
    - The scripted model plays the same script on each pass. A script with a `runCode` shell run on each pass makes mail on each pass, and thus loops to `mailOnlyAnswerLimit`. To make the script finite, the test support gets a step that plays its sub-steps only when the prompt of the pass contains a given text. The caller prompts of A and B carry different texts, and the mail-started answer has neither text.
    - Planned scenario: B's first pass starts `cat release.fifo` in the background and ends. A's pass holds (`.holdUntilReleased`). The test writes B's pipe. B's mail-started answer waits for a queue place (`waitingCount == 1`). Then `session/close` for B.
  timestamp: 2026-09-29T17:54:57.100311+00:00
- actor: claude-code
  id: 01m3q5abeebtn7njqpq5m3bn1y
  text: |-
    Implementation landed. No production code changed. The close answers: Router `close()` -> `drain()` -> `cancel()` removes the mail-started submission from the generation queue.

    - Test: `closeEndsAMailStartedAnswerThatWaitsForTheModelQueue` in CancellationTests.swift, with `.timeLimit(.minutes(1))`. B's prompt starts `cat release.fifo` in the background and ends. A's prompt holds the model (`.holdUntilReleased`). The test writes B's pipe, so the run settles and its mail starts an answer of B. The test waits for `waitingCount == 1`, then sends `session/close` for B. The close answers in about 1 s while A has no idle. After the release, A ends `end_turn`.
    - The script is finite: new step `ScriptedTurnStep.onPrompt(containing:play:)` in the test support (ScriptedModel.swift). It plays its sub-steps only when the prompt of the pass contains the marker. B's prompt and A's prompt carry different markers. The mail-started answer carries no marker, so it plays one text delta and ends, and it starts no new background run.
    - New test support `Support/NamedPipe.swift`: `makeDirectory(holding:label:)` (moved from a private helper in PromptTurnTests.swift, which now calls it) and `write(_:toPipeAt:)`. The write polls `open(O_WRONLY | O_NONBLOCK)` until a reader holds the pipe. Thus the text is never discarded in a pipe that no reader holds. No sleep.
    - Proof that the test can fail: for one run I removed `await cancel()` from `runDrain()` in the Router checkout (.build/checkouts/FoundationModelsRouter, RoutedSessionActorDrain.swift). The test failed at the 60 s time limit. I restored the file; `git status` of the checkout is clean.
    - Why the observation of ^m0k2vn6 differs: I did not reproduce it. In that shape B looped to `mailOnlyAnswerLimit`, so the queue was never free. This test shows that the close itself does not wait for a queued mail-started answer.

    Test counts: `swift test --filter closeEndsAMailStartedAnswerThatWaitsForTheModelQueue` passed. `swift test` passed 615 tests in 70 suites. The one known issue is the old deliberate `withKnownIssue` in HarnessSmokeTests. The compiler gave no warnings. The only warning line is the build-system line "missing creator for mutated node" for the mlx bundle, which was there before.
  timestamp: 2026-09-29T18:02:34.830746+00:00
- actor: claude-code
  id: 01m3q5adnd08jb545czwga06xw
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/CancellationTests.swift (new test), Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift (`onPrompt(containing:play:)` step), Tests/FoundationModelsACPAgentTests/Support/NamedPipe.swift (new), Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift (uses NamedPipe). `swift test`: 615 tests in 70 suites passed, 0 compiler warnings. Mutation check: without `cancel()` in Router `runDrain()` the test fails at the 60 s time limit.
    - next: /review
  timestamp: 2026-09-29T18:02:37.101653+00:00
- actor: claude-code
  id: 01m3q5rg472f9nvtym40t8w7qx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit e1eb32e). The engine did 7 validator runs on 4 source files. It found 0 findings (0 confirmed, 0 refuted, 0 failed). The .reviewignore rule excluded 4 .kanban files. The task has no prior review findings.
    - next: none. The task moved to done.
  timestamp: 2026-09-29T18:10:18.375041+00:00
- actor: claude-code
  id: 01m3q5rqqkjcxvventvwhwdyhm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files (CancellationTests.swift, ScriptedModel.swift, Support/NamedPipe.swift new, PromptTurnTests.swift)
    - test: green — swift test 615 tests pass; IntegrationTests build ok; Router checkout clean
    - commit: e1eb32e
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-29T18:10:26.163272+00:00
position_column: done
position_ordinal: f480
title: Prove or rule out a session/close hang when a mail-started answer waits for a place in the model queue
---
## Why

The work on ^m0k2vn6 saw one `session/close` that did not return in 60 s (see the first comment of ^6kcts5v). The tests of ^6kcts5v prove that a close ends a CALLER prompt that waits for a queue place. They do not examine an answer that the MAIL of a settled background run starts. That shape is still open.

## Reproduction of the earlier observation (from ^6kcts5v)

1. Two sessions on one queued scripted model (one pool entry). Each session has its own working directory.
2. The script is one `runCode` with `tools.shell.execute({ command: "cat release.fifo && rm release.fifo" })`.
3. The cwd of A holds a named pipe `release.fifo`. The cwd of B holds a plain file with that name.
4. B's shell run settles at once. Its mail starts mail-only answers. Each answer plays the script again, so B loops until `mailOnlyAnswerLimit` (100).
5. The test writes A's pipe. A's shell run settles, and A has mail that waits for the queue.
6. `session/close` for A does not return in 60 s. A's mail answer never gets a pass (the log shows no second `runCode` for A).

## What

1. Write a test with a time limit that makes one session hold the model (`.holdUntilReleased`) while a mail-started answer of the other session waits for a queue place. Then close the waiting session.
2. If the close does not answer, find if the cause is Router `close()`/`drain()`. If it is, record the defect with exact steps for the Router session. Do not work around it in this repository.

## Acceptance Criteria

- [x] A test proves that `session/close` answers while a mail-started answer of that session waits for a queue place, or the card records a Router defect with reproduction steps.

#generation-queue