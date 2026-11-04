---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6kstt9v384b5tjkabvg6w1r
  text: |-
    ### implement — changed
    - evidence: commit 60d4232 on branch wt-quit (worktree FoundationModelsACPAgent-wt-quit), not pushed, not merged. 4 files: Sources/FoundationModelsACPAgent/RoutedACPAgent.swift (new shutdownAfterConnectionTeardown: shutdown first, then waitForConnectionTeardown), Sources/FoundationModelsACPAgent/ComposedAgent.swift (delegates to it), Tests/FoundationModelsACPAgentTests/ProcessQuitShutdownTests.swift (new), Tests/FoundationModelsACPAgentTests/OrderlyShutdownTests.swift (Working and startWorking no longer private). No change to SessionSetup, ConfigOptions, SessionResume*, or a sibling package.
    - cause (found by reading, proved by test): the process path was connection.close(), then waitForConnectionTeardown(), then shutdown(). The ACP `closed` value (which the teardown task awaits) waits for the DEFERRED work of every handler. For session/prompt that work includes endTelemetryAfterPrompt, which waits for the end of the prompt. So the wait blocked until the prompt ended. The prompt with an agents call ends only after the inline settle grace (about 5 s, inlineSettleGrace): the call then completes (succeeded) and the child moves to the background. Only after that did shutdown() run, so it paused nothing and the journal already held completed for the call. A direct agent.shutdown() (the d6vzdkg tests) skipped the wait, which hid this. SIGTERM and stdin close take the same path. The pause code of ^d6vzdkg is correct; it ran too late.
    - fix: shutdown() first (it closes every open session, also one a connection owns, pauses the open calls, ends the open prompts as interrupted, stops the runs), then waitForConnectionTeardown(), which then returns because the prompt ended. session/close and session/delete are untouched and still cancel.
    - TDD: RED = aQuitWithAnOpenPromptLeavesTheRunOrphanedInTheJournal, 2 cases (closed input, SIGTERM) failed: journal held completed(succeeded), not orphaned; the quit took about 7 s. GREEN: same tests pass in 0.9 s. Tests that passed at once and pin kept behaviour: paused agents call (history), no ended marker, and the no-open-prompt case (root idle after the grace, child in the background, quit: no ended marker). The old order already kept the history status paused by a different timing, only the journal showed the failure.
    - tests run (unit only): `swift test --filter "ProcessQuitShutdownTests|OrderlyShutdownTests|ComposedAgentTests|HeadlessCLITests|ConnectionCloseTests|InterruptedToolCallsTests|ClosingOrderTests"` 30 tests in 7 suites passed. Full suite not run in this worktree by order of the run rules (touched suites once).
    - NOT done: the integration tests with real binaries (3 quits). IntegrationTests does not build inside a worktree folder (its package names the parent by directory name), so I did not write code I cannot compile. CI must run them; the three acceptance boxes that need a real process and the integration test box stay open. The existing RedriveInterruptedRunsProcessTests uses SIGKILL because of this bug; once CI shows the fix, it may use stdin close and SIGTERM too.
    - Agents package: no cancel by itself on a run-host stop found; `AgentRunner.stop()` is cancelForShutdown and leaves the session unended (log "left its suspended session unended"). No host API is missing.
    - boxes: "session/close and session/delete still cancel" ticked (OrderlyShutdownTests aUserCloseCancelsTheAgentsCallOfTheRoot, aUserCloseMarksTheRunEndedAsCancelled pass). Others open.
    - next: /review, then CI integration run.
  timestamp: 2026-11-04T17:31:13.595436+00:00
- actor: claude-code
  id: 01m6ktq2hghsmfe39b2g462cjg
  text: |-
    ### review — clean
    - evidence: review sha 8715d82~1..8715d82, 4 files reviewed, findings 0, confirmed 0, refuted 0, attempted 7, failed 0, skipped 0.
    - next: Task moved to done by order of the user. These boxes stay open on purpose: the three acceptance boxes for stdin close, SIGTERM, and quit with no open root prompt, and the test box "Integration tests with real binaries for the three quits". Reason: CI runs the integration tests; the user ordered that integration tests are not run in development. The box "Run the full swift test" also stays open: only the touched suites ran (30 tests in 7 suites).
  timestamp: 2026-11-04T17:46:39.536774+00:00
- actor: claude-code
  id: 01m6kxq7ajcb0shyj91zbrsbyz
  text: |-
    ### implement — changed
    - evidence: commit c6ac0b8 on wt-late. The three `_ = await working.promptTask.result` lines in ProcessQuitShutdownTests now use `try await working.finishPrompt()`, so a prompt failure fails the test. Suite ProcessQuitShutdownTests passed (the prompt ends without an error on quit).
    - next: review
  timestamp: 2026-11-04T18:39:10.162185+00:00
position_column: done
position_ordinal: ffffb680
title: 'Process quit (stdin close or SIGTERM) with an open root prompt cancels the prompt and the child: pause them instead'
---
## What
Found by the implement step of ^C0991F (real binaries, integration test `RedriveInterruptedRunsProcessTests`). Task ^d6vzdkg made an orderly `agent.shutdown()` pause the open tool calls and not cancel them. The real process does not follow that rule in two cases:
- A quit by stdin close or SIGTERM while a root prompt is open cancels the prompt and the child. The child then ends as `finished` and is not restorable.
- A quit while the root has no open prompt cancels the child after the run grace (about 5 s).

Only a SIGKILL leaves an interrupted child that a cold resume can re-drive.

## Do
1. Reproduce with the real binary (`acp-agent-launcher` / `acp-agent-stub`, see `IntegrationTests/.../RedriveInterruptedRunsProcessTests.swift` and `SpawnedACPAgent.killAndWait`): start a nested run, then close stdin, then SIGTERM. Find which path the process takes (for example `ComposedAgent.shutdownAfterConnectionTeardown()`, `closeSessions(where:isShutdown:)`, the connection-teardown path, the run grace in AgentRunHost) and why it does not reach the `isShutdown` pause of ^d6vzdkg (`SessionShutdownPause.swift`, `tearDownSession`).
2. Make an orderly process quit pause the open tool calls of the root and of each running child, and suspend the agent runs without cancelling them, in both cases above. `session/close` and `session/delete` keep cancelling.
3. Do not change a sibling package. If the Agents package cancels the child by itself on a run-host stop (the run grace), say which API a change needs and mark the task stuck.

## Acceptance Criteria
- [ ] After a stdin close with an open root prompt, a cold resume restores the child and re-drives it (integration test with real binaries).
- [ ] After a SIGTERM with an open root prompt, the same.
- [ ] After a quit with no open root prompt, the child is not cancelled by the run grace, and a cold resume re-drives it.
- [x] `session/close` and `session/delete` still cancel.

## Tests
- [ ] Integration tests with real binaries for the three quits.
- [ ] Run the full `swift test`. All pass.

## Workflow
- Use `/tdd`. #subagents

## Review Findings (2026-11-04 12:30)

> Scope: late review of a wide range of commits, on code of a task that was already `done`.

- [x] `Tests/FoundationModelsACPAgentTests/ProcessQuitShutdownTests.swift:59` `test-integrity/no-test-cheating` — The test discards the result of the root prompt task with `_ = await working.promptTask.result`. An error that the prompt throws is never checked, so the test can pass when the prompt failed. Wait for the prompt with `try await working.finishPrompt()` (or assert the expected `Result` case explicitly), so a prompt failure fails the test. If the prompt is expected to end with an error on quit, assert that error by type.
