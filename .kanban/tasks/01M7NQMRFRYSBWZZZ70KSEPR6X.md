---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qqpde0c4v4dc3w1ff7j6cc
  text: |-
    Research. Router 709d82c `RouterSessionDirectory.inbox(of:markRead:)` marks the messages read in the ledger, sends `messageDelivered` for each message whose mail waits (`sendDelivered`), then cancels the waiting mail (`withdrawWaitingMail` -> `RoutedSession.cancel`). The target session then gives `SessionEvent.cancelled(MailID)`, never `mailDelivered`. Today the translator ignores `.cancelled`, so the projector keeps the message in `directoryMessages` and gives no view.

    Plan. `.cancelled(mail)` of the target is the receive step of a read in the inbox. The directory event and the session event come in two tasks, so either can come first. When the projector knows the message (`messageDelivered` came), the cancel gives the view. When it does not know it, the projector reads the directory, and accepts the message only when `isRead` is true (a cancel for an other cause, for example `cancelAll`, has an unread message and gives no event of the directory). `directoryKeys` stops a second view (second read, later take).
  timestamp: 2026-11-18T16:26:31.744023+00:00
- actor: claude-code
  id: 01m7qzb297xcgjqv4nthmz3xk2
  text: |-
    Implementation landed (no commit).

    - `SubagentMessageProjector.withdrawn(_:from:)`: the `cancelled` event of the target is the receive step of a read in the inbox. A kept directory message gives its view. When the cancel comes before `messageDelivered`, the projector reads the directory and accepts only a message with `isRead == true`. `directoryKeys` stops a second view.
    - `ACPEventTranslator`: `.cancelled(mail)` has its own arm and calls `receiveReadMessage(of:)`.
    - Tests: 5 new projector tests, 3 new wire tests (`DirectoryMessageWireTests`). RED seen for each: 4 projector tests failed, 3 wire tests failed with the wait bound; the test "a withdrawn mail that the target did not read gives no view" is a guard and passed before the change.

    Discoveries.
    - A message from a session to a durable target goes through an inbox FILE; the directory scans it in its own task. An inbox read before the scan reads nothing. Under the load of the full suite this race made the new wire tests fail. The wire tests now wait until `inbox(markRead: false)` holds the message (`Pair.waitUntilInInbox`).
    - The first RED run had no end: `collector.wait` waits forever, and `.timeLimit` cancels the test task, then `session/close` in the fixture close fails and `harness.close()` hangs while the busy turn waits at its gate. Fix: each wait of the suite has its own bound (`bounded(by:_:)`, moved from `ScheduledAgentEndToEndTests` to `Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift` so both suites share it). The suite also has `.timeLimit(.minutes(1))`.
  timestamp: 2026-11-18T18:40:08.487963+00:00
- actor: claude-code
  id: 01m7qzb662e1m407887vz02ft7
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsACPAgent/Agent/SubagentMessageProjector.swift, Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift, Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator+Messages.swift, Sources/FoundationModelsACPAgent/Agent/DirectoryMessage.swift, Tests/FoundationModelsACPAgentTests/DirectoryMessageProjectorTests.swift, Tests/FoundationModelsACPAgentTests/DirectoryMessageWireTests.swift, Tests/FoundationModelsACPAgentTests/ScheduledAgentEndToEndTests.swift, Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift
    - next: review

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings (one SwiftPM build-graph line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" that is not from this change); `swift test --skip-build`: 2323 tests in 246 suites passed, 0 failures, 1 known issue (the deliberate `withKnownIssue` self-test HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps).
    - next: review
  timestamp: 2026-11-18T18:40:12.482626+00:00
- actor: claude-code
  id: 01m7rf59686gmywy42pak767pf
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 1 finding (1 confirmed, 3 refuted, 0 failed). Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift:15 (swift/concurrency). The first run had 3 of 7 failed review tasks. That result was not complete, so the review ran again.
    - next: implement the finding. Send the cancellation of the caller to the `work` task in `bounded(by:_:)`. Then commit and review again.
  timestamp: 2026-11-18T23:16:36.168299+00:00
- actor: claude-code
  id: 01m7rf5pg8y2pnq5475w016c6j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 8 files
    - test: green — swift test --skip-build, 2323 tests in 246 suites passed; 0 compiler warnings
    - commit: 13445d1
    - review: findings — Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift:15
  timestamp: 2026-11-18T23:16:49.800743+00:00
- actor: claude-code
  id: 01m7rfhv3ppdhpwrf4e6z56dxe
  text: |-
    Finding `BoundedWait.swift:15` `swift/concurrency` done.

    - `bounded(by:_:)` now runs `body` and the timer as two child tasks of one `withThrowingTaskGroup`. No unstructured `Task { }` stays in the file (the `limit` task also went). A cancel of the caller cancels both children. The timer child uses `try? Task.sleep`, so a cancel of the caller ends it early, the group cancels the body, and the result or error of the body stays the result of the wait (the same contract as before).
    - New test `Tests/FoundationModelsACPAgentTests/BoundedWaitTests.swift` `aCancelOfTheCallerCancelsTheBody` (bound 3600 s, `.timeLimit(.minutes(1))`). RED: time limit exceeded after 60 s, `cancelled` false. GREEN: passed in 0.001 s.
    - Full suite: 2324 tests in 247 suites, 1 failure: `ResumeChildSyncTests.theWireOfTheResumeFollowsTheRulesOfTheValidator(replays: false)` gave an `announceBeforeUse` violation. That suite does not use `bounded`, and passed alone (24 tests). It is a race under load; a new task records it.
  timestamp: 2026-11-18T23:23:27.734967+00:00
- actor: claude-code
  id: 01m7rfj2r4t47j0sqjkbp6vv2k
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift, Tests/FoundationModelsACPAgentTests/BoundedWaitTests.swift (new)
    - next: review

    ### test — red
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (1 SwiftPM build-graph line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", not a compiler warning, also present before this change). `timeout 1800 swift test --skip-build`: 2324 tests in 247 suites, 1 failure (ResumeChildSyncTests.theWireOfTheResumeFollowsTheRulesOfTheValidator(replays: false), announceBeforeUse violation), 1 known issue (the deliberate withKnownIssue self-test). The failing suite does not use `bounded`, and it passed alone (24 tests). The race is recorded as ^avdk50h.
    - next: review of this finding; ^avdk50h for the race.
  timestamp: 2026-11-18T23:23:35.556913+00:00
- actor: claude-code
  id: 01m7rfprjpbgagbyeptbqq984k
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (043a781). 0 findings, 0 confirmed, 0 refuted. 7 review tasks ran, 0 failed. Files reviewed: Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift and Tests/FoundationModelsACPAgentTests/BoundedWaitTests.swift. The prior finding at BoundedWait.swift:15 is checked.
    - next: none. The task moved to done.
  timestamp: 2026-11-18T23:26:08.982194+00:00
- actor: claude-code
  id: 01m7rfq7tr44dy5gzaqhen230d
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — BoundedWait.swift, BoundedWaitTests.swift; 1/1 finding checked
    - test: green — swift test --skip-build, 2324 tests in 247 suites passed on the second full run (the first full run had 1 failure in ResumeChildSyncTests, which passes alone; recorded as ^avdk50h)
    - commit: 043a781
    - review: clean — 0 findings
  timestamp: 2026-11-18T23:26:24.600508+00:00
depends_on:
- 01M7NQMF7QKY4Q0E6REQA7BTPC
position_column: done
position_ordinal: ffffff8480
title: 'ACPA-6: show a directory message that the session reads with inbox, once'
---
Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, item 3. Decision D199 (f) in `TestudoApp/features/decisions.md`.

## Dependency

^qa7btpc (the `session_message` update for a delivered directory message). The Router puts a message for a recorded target into its inbox file (`router-brief-at-sessions.md`).

## Change

A directory message that the session reads with `inbox` (no turn starts) still gives one `session_message` update to the client of the target, with the same `_meta.sah.message` sender as in ^qa7btpc. Read the message one time only: a second `inbox` read, or a later turn, does not send it again.

## Tests

- A message in the inbox, read with `inbox`: one `session_message` update with the correct sender kind.
- A second read does not send a second update. #d199 #at-sessions #acpa-6

## Review Findings (2026-11-18 17:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 20 not reviewed.

> 20 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 20 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Support/BoundedWait.swift:15` `swift/concurrency` — The `work` task is an unstructured `Task { }`, and no cancellation reaches it from the caller. If the task that calls `bounded(by:_:)` is cancelled, `work` keeps running `body` until the bound fires. Only the `limit` task is cancelled, and only by the sleep timer. Wrap the await in `withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }`, or run `body` with `withThrowingTaskGroup` next to a sleeping child task so the group cancels both when the caller is cancelled.
