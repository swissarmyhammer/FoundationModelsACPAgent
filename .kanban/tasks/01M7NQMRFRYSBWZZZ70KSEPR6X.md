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
depends_on:
- 01M7NQMF7QKY4Q0E6REQA7BTPC
position_column: doing
position_ordinal: '8180'
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