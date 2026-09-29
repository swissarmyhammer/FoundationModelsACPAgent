---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q0yhzpvgvrj88rsbtbt6gc
  text: |-
    Research, picked up in doing.

    The card is older than the code. State at HEAD 87f3ead:
    - Router main has no `RoutedSession.awaitingUser`. Commit 4ac665b changed `TurnStateOwner.awaitingUser(_ body:)`: it sends requires_action, runs the body, then sends running. It takes no session. The card step "keep the call to session.awaitingUser(body)" is obsolete. I do not add the call back.
    - The test is already named `awaitingUserPairsRequiresActionWithRunning`, with no "gate" text.
    - The doc comments of TurnState.swift and ElicitationRelay.swift already use the queue model. Only `ActiveSession.descendants` in SessionSetup.swift still says "model gate".
    - `swift package update FoundationModelsRouter`: "Everything is already up-to-date". Package.resolved pins c49e453, which is Router main HEAD.

    Router contract (generation-queue.md 5.5 and 5.7): a submission holds its model from its first pass to its answer, and in-band tool bodies count in it. A `BackgroundTool` (runCode) holds the model only for `inlineSettleGrace` (5 s, Multitool default). After that the run goes to the background and the submission ends. So a wait in a background run body, or an elicitation from it, holds no model after the grace. The two proofs use `runCode`:
    - Elicitation: the snippet calls the sandbox global `elicit(...)`. No MCP server is necessary.
    - Tool body: the snippet runs a shell `cat` on a named pipe that the test writes only at the end.
    The scripted script is the same for both sessions. For the elicitation proof the client answers only B. For the tool-body proof, B has its own working directory, where the pipe name is a plain file.
  timestamp: 2026-09-29T16:46:14.006856+00:00
- actor: claude-code
  id: 01m3q1x8435nbeg7542t2e1x2y
  text: |-
    Implementation landed. Not committed.

    Changes:
    - `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`: the `ActiveSession.descendants` doc comment says "no orphan keeps a run or a submission in the model queue", not "model gate".
    - `Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift`: the same text fix in the doc comment of `closingASessionClosesItsDescendants` (the rg gate also reads Tests).
    - `Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift`: `make` takes an optional `workingDirectory`; `waitForIdle(of:)` uses `Poll.until` (30 s deadline, not 10 s); new `updates(of:)`, `pendingElicitations(of:)` and `closeSessions()`.
    - `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: `aSessionInAnElicitationHoldsNoModel` and `aSessionInAToolBodyHoldsNoModel`, each with `.timeLimit(.minutes(1))`.

    How the proofs work:
    - Elicitation: the script is one `runCode` with `elicit("...")`. A elicits first, and the client does not answer it. B prompts. B's elicitation comes after the 5 s inline grace of A's `runCode`, the client answers only B, and B ends with `end_turn`. A's elicitation stays pending and A sends no idle. The test takes about 5.5 s.
    - Tool body: the script is one `runCode` with `tools.shell.execute({ command: "cat wait.fifo" })` on a named pipe that nothing writes. `execute` is a background mount, so the shell run holds no model. B's prompt ends with `end_turn` while A's `cat` waits. B's own read waits too (same script). `closeSessions()` stops both reads (killpg). The test takes about 1 s.
    - Both proofs passed at the first run: the Router (c49e453) already gives this behavior. They are regression proofs.

    What did not work (do not repeat):
    - A release of the pipe (write, then `rm`) makes the settled shell run send mail. The scripted model replays the whole script on each mail answer, so each answer starts a new shell run, and its mail starts the next answer: a loop of up to `mailOnlyAnswerLimit` (100) answers. Two working directories (B with a plain file) gave the same loop for B.
    - In that state, `session/close` of A did not return in 60 s: A had settled-run mail that waited for the model queue while B looped, and the close never ended, also after B's mail delivery paused. I did not find the cause. It can be a Router close/drain defect for a session whose mail answer waits for a queue place. Noted on ^6kcts5v, which owns close of a request that waits for the queue.
    - `tools.files.read` cannot wait on a named pipe: PathGuard refuses a path that is not a regular file.

    Results: `swift test --filter PromptTurnTests`: 33 tests pass. `swift test`: 611 tests in 70 suites pass (609 + 2 new), with 1 known issue (the `withKnownIssue` of HarnessSmokeTests). No compiler warning. The only warning line is the SwiftPM build note "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which comes from the mlx dependency and not from this change. `rg -n "model gate|Router gate|opens Router" Sources Tests` gives no result.
  timestamp: 2026-09-29T17:02:59.715201+00:00
- actor: claude-code
  id: 01m3q1xq3g3v4bte51sn14fs4q
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift, Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift; `swift test --filter PromptTurnTests` 33 pass; `swift test` 611 tests in 70 suites pass (1 known issue, the existing withKnownIssue of HarnessSmokeTests); no compiler warning; `rg -n "model gate|Router gate|opens Router" Sources Tests` gives no result.
    - next: /review. The card stays in doing.
  timestamp: 2026-09-29T17:03:15.056557+00:00
- actor: claude-code
  id: 01m3q2a0xvb3v85m777e6hgrjs
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 2d7ecb5). 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift:757 (reuse/reuse).
    - next: Move `waitForPendingElicitation` to Tests/FoundationModelsACPAgentTests/Support/ as one shared helper. Make PromptTurnTests and ElicitationRelayTests use it. Then do the review again.
  timestamp: 2026-09-29T17:09:58.331913+00:00
- actor: claude-code
  id: 01m3q2abxk6cbhhvyytzkgk02m
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files (SessionSetup.swift, PromptTurnTests.swift, SessionLifecycleTests.swift, QueuedScriptedFixture.swift)
    - test: green — swift test 611 tests pass; IntegrationTests build ok
    - commit: 2d7ecb5
    - review: findings — Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift:757
  timestamp: 2026-09-29T17:10:09.587775+00:00
- actor: claude-code
  id: 01m3q2gqw9rw6qpf8j512p7gbg
  text: |-
    Review finding corrected: `waitForPendingElicitation` duplicated a helper in ElicitationRelayTests.swift.

    Changes:
    - New `Tests/FoundationModelsACPAgentTests/Support/ElicitationPoll.swift`: the enum `ElicitationPoll` with `pendingElicitations(of:on:)` (the one MainActor read of `SwiftUIACPClient.pendingElicitations(for:)`) and `firstPendingElicitation(of:on:sourceLocation:)` (a `Poll.until` wait, then `#require` on the first pending elicitation). No hard wait.
    - `PromptTurnTests.swift`: removed the private `waitForPendingElicitation`; `aSessionInAnElicitationHoldsNoModel` calls `ElicitationPoll.firstPendingElicitation` two times.
    - `ElicitationRelayTests.swift`: removed the private `waitForPendingElicitation` (a `maxPollAttempts` / `Task.sleep` loop with the same filter); its four callers call `ElicitationPoll.firstPendingElicitation` directly.
    - `QueuedScriptedFixture.pendingElicitations(of:)` now uses `ElicitationPoll.pendingElicitations(of:on:)`, so no other copy of the MainActor read stays in Tests.

    The ElicitationRelayTests wait moves from the `ScriptedTurnFixture` loop (500 x 20 ms = 10 s) to `Poll.until` (30 s deadline, 50 ms interval).

    Results: `swift test`: 611 tests in 70 suites pass, 1 known issue (the existing `withKnownIssue` of HarnessSmokeTests). The four ElicitationRelayTests round trips and the two PromptTurnTests proofs pass. No compiler warning. The only `warning:` line is the SwiftPM note "missing creator for mutated node ... mlx-swift_Cmlx.bundle" from the mlx dependency.
  timestamp: 2026-09-29T17:13:38.441276+00:00
- actor: claude-code
  id: 01m3q2gte5za3v7y3m244qtmpk
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsACPAgentTests/Support/ElicitationPoll.swift (new), Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/ElicitationRelayTests.swift, Tests/FoundationModelsACPAgentTests/Support/QueuedScriptedFixture.swift; `swift test` 611 tests in 70 suites pass (1 known issue, the existing withKnownIssue of HarnessSmokeTests); no compiler warning; review finding PromptTurnTests.swift:757 flipped to [x].
    - next: /review. The card stays in doing. Not committed.
  timestamp: 2026-09-29T17:13:41.061892+00:00
depends_on:
- 01M3A37J8X6VKD5BKYWSJ4HCZD
position_column: doing
position_ordinal: '8180'
title: Make awaitingUser a plain requires_action wrapper, and prove a waiting session holds no model
---
## Why

The Router task "Delete the permit loan and the human-wait release" (FoundationModelsRouter card `01M39ZP766H4S63AR4R44Y6BA4`) makes `RoutedSession.awaitingUser(_:)` a pass-through: a person wait holds nothing, and a tool wait holds nothing. The API stays, so this agent still compiles. But the text here says the wrong thing:

- `TurnStateOwner.awaitingUser(on:_:)` (`Sources/FoundationModelsACPAgent/Agent/TurnState.swift:121-144`) says it "opens Router's model gate".
- `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift:661-690`: `awaitingUserPairsRequiresActionWithTheRouterGate`.
- `ActiveSession.descendants` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:93`): "no orphan holds a model gate".
- `ElicitationRelay.swift:24`, `:83`.

Decision in this plan: keep the call to `session.awaitingUser(body)`. It is free, and it keeps the Router contract if the Router gives it a new purpose later. The ACP part (`requires_action`, then `running`) does not change.

**Obsolete (2026-09-29):** Router main has no `RoutedSession.awaitingUser` now. Commit 4ac665b changed `TurnStateOwner.awaitingUser(_ body:)`: it sends `requires_action`, runs the body, then sends `running`, and it takes no session. The step "keep the call to `session.awaitingUser(body)`" cannot apply. The call is not added back. The TurnState.swift and ElicitationRelay.swift comments and the test rename were already done in 4ac665b.

## External dependency

Router card `01M39ZP766H4S63AR4R44Y6BA4` on Router `main`.

## What

1. `swift package update FoundationModelsRouter`.
2. Update the doc comments above to the queue model: a wait holds no model; the ACP state still goes `requires_action` → `running`.
3. Rename the test `awaitingUserPairsRequiresActionWithTheRouterGate` to `awaitingUserPairsRequiresActionWithRunning` and remove "gate" from its text.
4. Add the end-to-end proof of the queue benefit at the ACP level.

## Acceptance Criteria

- [x] Two ACP sessions on one model: A is in an elicitation round trip that the client does not answer. B sends a prompt, and B's prompt completes with `end_turn` while A still waits.
- [x] Two ACP sessions on one model: A is in a tool body that waits (a scripted tool that waits on a continuation). B's prompt completes while A waits.
- [x] `rg -n "model gate|Router gate|opens Router" Sources Tests` gives no result.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: `aSessionInAnElicitationHoldsNoModel`, `aSessionInAToolBodyHoldsNoModel`, with a timeout.
- [x] Run `swift test --filter PromptTurnTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue

## Review Findings (2026-09-29 12:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift:757` `reuse/reuse` — Function `waitForPendingElicitation` duplicates an existing test helper with 0.92 similarity. An identical function already exists in ElicitationRelayTests.swift; both test files are reinventing the same poll-and-filter pattern instead of sharing it. Move `waitForPendingElicitation` to Tests/FoundationModelsACPAgentTests/Support/ as a shared helper function so both PromptTurnTests and ElicitationRelayTests can call the same implementation.
