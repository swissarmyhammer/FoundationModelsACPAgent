---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tyjhhvxqvt5t4ehpfycx2p
  text: |-
    Research done.
    - Callers of `BlockingFIFO.openWriteEnd(at:)`: `NamedPipe.write(_:toPipeAt:)` (unit tests: AgentsToolTests, PromptFollowUpTests, CancellationTests, MailDeliveryPauseFixture) and `StubChunkGateWriter.open(at:)` (IntegrationTests package).
    - Readers: a shell `cat <pipe>` inside a scripted run, a `.gate(path:)` step of the scripted stub, and the spawned stub model process (chunk gate). Each reader opens the read end with a blocking open. On Darwin, a reader that waits in its open already counts as a reader, so an open of the write end with `O_NONBLOCK` succeeds while that reader waits, and fails with `ENXIO` while no reader is there.
    - Design: open with `O_WRONLY | O_NONBLOCK` in a loop. Between two attempts, `Task.sleep` (a cancel ends it). A time limit (default value, the caller can give a shorter one) ends the loop with a typed error. After the open, clear `O_NONBLOCK`, so the writes block as before. No thread blocks in the kernel any more, so nothing can stay for ever.
  timestamp: 2026-11-19T22:24:28.219351+00:00
- actor: claude-code
  id: 01m7tyyx155gvbp0xw8a3qcw0h
  text: |-
    Implementation landed.
    - RED: the new suite `BlockingFIFOTests` (3 tests, each `.timeLimit(.minutes(1))`) ran against the old body (only the new parameter and the error type were added). The run hung past the 1-minute limit until `timeout 180` stopped `swift-test`. Important discovery: the Swift Testing `.timeLimit` does not end a test whose task never returns, and the `swiftpm-testing-helper` child stays as an orphan (parent pid 1) after the outer timeout. This is the source of the old orphaned helpers. The orphan of this run was stopped by pid.
    - GREEN: `openWriteEnd(at:waitingAtMost:)` opens with `O_WRONLY | O_NONBLOCK` in a loop, `Task.checkCancellation()` and a `Task.sleep` of 10 ms between attempts, and a deadline on `ContinuousClock` (default `BlockingFIFO.defaultReaderWait` = 120 s). At the deadline it throws `BlockingFIFOError.noReader(path:limit:)`. After the open it clears `O_NONBLOCK` and sets `F_SETNOSIGPIPE`. The new suite passed in 0.212 s.
    - Doc comments of `NamedPipe.write` and `StubChunkGateWriter.open` now link the new symbol.
  timestamp: 2026-11-19T22:31:13.189297+00:00
- actor: claude-code
  id: 01m7tz1f4kdh88vfvc58tmz7kj
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift (bounded, cancellable open with O_NONBLOCK and a retry loop; BlockingFIFOError.noReader), Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift (new, 3 tests), Tests/FoundationModelsACPAgentTests/Support/NamedPipe.swift and IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/StubChunkGateWriter.swift (doc comments only).
    - test: `timeout 1800 swift test --skip-build` — 2650 tests in 280 suites passed, 0 failures, 1 known issue (the existing withKnownIssue in HarnessSmokeTests). `swift build --build-tests` printed "Build complete!" with 0 compiler warnings. The IntegrationTests package was not built; its one change is a doc comment, and its call uses the default parameter.
    - next: /review
  timestamp: 2026-11-19T22:32:37.267898+00:00
- actor: claude-code
  id: 01m7tz8jjke277mnbs9tj21spw
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 5 findings (5 confirmed, 1 refuted, 0 failed) — Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift:21, Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift:25, Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:26, Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:62, Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:72
    - next: correct each finding in the "Review Findings (2026-11-19 16:33)" section, then run the review again.
  timestamp: 2026-11-19T22:36:30.163735+00:00
position_column: review
position_ordinal: '80'
title: BlockingFIFO.openWriteEnd(at:) can wait for ever for a reader, and nothing cancels it
---
Found during ^6yqbvx6 (2026-11-19).

## What happened

In a full parallel run under load, one test process hung until the loop killed it. Its stack sample shows a thread blocked for ever in `BlockingFIFO.openWriteEnd(at:)` (`Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift`). The open of the write end of a FIFO blocks until a reader opens the read end. When the reader never comes (for example, the test that should read stopped, failed, or was cancelled), the writer waits for ever, and nothing cancels it. The process then never ends, and the test run hangs until an outer time limit kills it. Old test processes can stay on the machine after that (four orphaned test helpers of this repo were found, about 5 hours old, and were stopped).

## Change

1. Find each caller of `BlockingFIFO.openWriteEnd(at:)` and what reader it expects.
2. Make the open bounded and cancellable: for example open with `O_NONBLOCK` in a loop with a time limit and a check for task cancellation (an open of the write end with `O_NONBLOCK` fails with `ENXIO` while no reader is there), or open the read end in the same helper first so the write open cannot block, or run the blocking open on a thread that a cancel can stop by opening the read end itself.
3. A failed or timed-out open throws a clear error, so the test fails and the process ends.

## Tests

- A write-end open with no reader ends with a clear error within the time limit.
- A cancel of the task that waits ends the wait.
- The normal case (a reader comes) still works. #test #flaky

## Review Findings (2026-11-19 16:33)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [ ] `Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift:21` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift:25` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:26` `reuse/reuse` — The test helper `makePipe(label:)` rebuilds a pipe directory by hand: it calls `makeResolvedDirectory`, appends the file name, and then calls `BlockingFIFO.makePipe`. The same test target already has `NamedPipe.makeDirectory(holding:label:)`, which does exactly this. The new code therefore duplicates an existing helper that the author could have called, and the two copies can drift apart. Replace the body of `makePipe(label:)` with a call to `NamedPipe.makeDirectory(holding: "pipe", label: "BlockingFIFOTests-\(label)")`, then append the file name to the returned directory. Or make the helper return the directory and use it from the tests.
- [ ] `Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:62` `test-integrity/no-test-cheating` — The cancel test calls `opener.cancel()` right after creating the task. The task most likely has not started, so the first `Task.checkCancellation()` in `openWriteEnd` throws before any sleep. The test then passes without showing that a cancel ends the wait during the retry sleep, which is the behavior its doc comment claims. A broken cancel inside the sleep loop would still pass. Make sure the task is inside the wait before cancelling. For example, wait until the task has made at least one failed attempt (a short sleep or a signal from a test hook), then call `cancel()`. Keep the `.timeLimit` so a cancel that is ignored still fails the test.
- [ ] `Tests/FoundationModelsACPAgentTests/BlockingFIFOTests.swift:72` `swift/concurrency` — The unstructured Task that runs openWriteEnd is not cancelled if the test fails before it awaits opener.value. If openReadEnd(at:) fails at its #require on line 75, the test body exits early, and the opener task keeps waiting for a reader for up to unreachedReaderWait (3600 s). The task is only cancelled on the success path. Cancel the task on every exit path, for example by adding `defer { opener.cancel() }` directly after line 72. Cancelling a task that has already finished is harmless.
