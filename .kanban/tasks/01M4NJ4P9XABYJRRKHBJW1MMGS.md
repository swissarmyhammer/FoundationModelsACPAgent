---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4njn47wfpk3h65br0psq4tr
  text: |-
    Research done.
    - `SinkRecorder` is an actor. `updates(until:)` keeps a `CheckedContinuation<_, Never>` that only `append` resumes. No cancellation handler.
    - Callers of `updates(until:)`: TerminalStreamTests (5 sites) and ToolCallJoinProjectionTests (4 sites and `updatesUntilOutput`).
    - Other waits with the same shape (a continuation that only a condition resumes): `HeldSink.waitUntilHolding` and the held send of `HeldSink.receive` in TerminalStreamTests.
    - Not the same shape: `ScriptedHold` (already ends on cancellation, Mutex pattern), polling waits with `Task.sleep` (they throw on cancellation), `for await` on an `AsyncStream` (ends on cancellation), `ScriptedTranscriptDeliveryTests` queue/semaphore waits (no condition), `BuiltExecutableRun` process exit (integration, no condition). `LateAnswerGate` ignores cancellation ON PURPOSE (its doc says so), so it stays.
    - Design: one shared helper `WatchedValue<Value>` in the unit test Support folder. The value and the waits are under one `Mutex`, because `onCancel` runs synchronously and must remove its wait at once. A wait resumes exactly one time: by the change that makes its condition true, or by cancellation. A cancelled wait throws `ConditionWaitCancelled`, whose description names the condition. `updates(until:)` gets a condition name and becomes `throws`.
  timestamp: 2026-10-11T13:32:52.348445+00:00
- actor: claude-code
  id: 01m4njtdz8jsnf1xgty4p6d48e
  text: |-
    Implementation landed.
    - RED: new `SinkRecorderTests` (3 tests) did not compile against the old API (no `ConditionWaitCancelled`, `updates(until:)` took no condition name). A run of the old wait with a cancel would hang, so the RED is the compile failure, not a hang.
    - GREEN: `swift test --filter SinkRecorderTests` -> 3 tests passed, each in about 0.001 s.
    - New `Tests/FoundationModelsACPAgentTests/Support/WatchedValue.swift`: `WatchedValue<Value>` (value and waits under one `Mutex`, `withTaskCancellationHandler`, exactly-one resume) and `ConditionWaitCancelled` (its description names the condition).
    - `SinkRecorder` now keeps its updates in a `WatchedValue`. `updates(until: "<condition name>") { ... }` is `async throws`.
    - `HeldSink` in TerminalStreamTests: the hold and `waitUntilHolding()` use one `WatchedValue<Phase>` (enum waitingForFirstSend/holding/released). `waitUntilHolding()` throws on cancellation; the held send ends on cancellation too.
    - All call sites in TerminalStreamTests and ToolCallJoinProjectionTests give a condition name.
    - Not changed on purpose: `LateAnswerGate` (it ignores cancellation by design, documented), `ScriptedHold` (already cancellation-aware).
    - IntegrationTests does not use the unit test target, so no integration run is necessary.
  timestamp: 2026-10-11T13:35:46.152549+00:00
- actor: claude-code
  id: 01m4njwgxdad38fn308vt6w56e
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsACPAgentTests/Support/WatchedValue.swift (new), Tests/FoundationModelsACPAgentTests/SinkRecorderTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift, Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift, Tests/FoundationModelsACPAgentTests/ToolCallJoinProjectionTests.swift. Full root `swift test --scratch-path .build/alt --force-resolved-versions`: 914 tests in 100 suites passed, 0 failures, EXIT 0; the 1 known issue is the deliberate `withKnownIssue` in HarnessSmokeTests (it was there before). XCTest: 0 tests. The only warning is the accepted "missing creator ... mlx-swift_Cmlx.bundle". IntegrationTests not run: it does not use the unit test target.
    - acceptance: item 1 met by the mechanism (`.timeLimit` cancels the test task, the wait throws `ConditionWaitCancelled` that names the condition, the run continues); item 2 met by a direct check of the cancelled wait (`SinkRecorderTests`), with no dependence on a time limit.
    - next: /review
  timestamp: 2026-10-11T13:36:54.701051+00:00
- actor: claude-code
  id: 01m4nka6w0at1k1dc0g3zd7qf8
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`: engine counts findings 0, confirmed 0, refuted 0 (7 attempted). The dead-code-swift failure comes from `.build/checkouts` only and does not count. Manual check: 1 finding — Tests/FoundationModelsACPAgentTests/SinkRecorderTests.swift:84 (`startWait` can return before the wait is kept, so the "suspended" cancel test does not always prove the `onCancel` path). Manual checks that pass: exactly one resume per wait (condition change and `onCancel` both remove the wait under the lock; `admit` reads `Task.isCancelled` under the lock, so a cancel before the wait is kept is not lost); no continuation leak; the held send of `HeldSink` continues on cancel (`try?`); with the old code the two cancel tests would hang. Tests: `swift test --scratch-path .build/alt --force-resolved-versions --filter "SinkRecorderTests|TerminalStreamTests|ToolCallJoinProjectionTests"` with a new empty SKILLS_MARKETPLACE_CACHE: 35 tests in 3 suites passed, exit 0.
    - next: /implement the open finding, then /review again.
  timestamp: 2026-10-11T13:44:23.168285+00:00
- actor: claude-code
  id: 01m4nky0tcfmj2qwm222wwynfz
  text: |-
    ### implement — changed
    - finding fixed: SinkRecorderTests.swift:84 `manual/test-determinism`. `WatchedValue.keptWaitCount` (read under the lock) and `SinkRecorder.keptWaitCount` were added. `startWait` no longer signals from inside the condition. It returns only when `keptWaitCount` is not 0 (loop: `Task.checkCancellation()` + `Task.yield()`, no sleep; it now throws). Its doc comment states the true condition. The cancel test asserts `keptWaitCount == 1` before `wait.cancel()` and `keptWaitCount == 0` after the throw, so it proves that the `onCancel` handler removed a kept wait.
    - evidence: 3 files — Tests/FoundationModelsACPAgentTests/Support/WatchedValue.swift, Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift, Tests/FoundationModelsACPAgentTests/SinkRecorderTests.swift. `swift test --scratch-path .build/alt --force-resolved-versions --filter "SinkRecorderTests|TerminalStreamTests|ToolCallJoinProjectionTests"` with a new empty SKILLS_MARKETPLACE_CACHE: 35 tests in 3 suites passed, exit 0, only the accepted mlx-swift_Cmlx.bundle warning. 50 runs of `--skip-build --filter SinkRecorderTests`: pass=50 fail=0.
    - next: /review
  timestamp: 2026-10-11T13:55:12.332722+00:00
position_column: done
position_ordinal: ffc680
title: SinkRecorder.updates(until:) ignores cancellation, so a failed wait hangs the test run
---
## Problem

`SinkRecorder.updates(until:)` in `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift` waits in a way that ignores task cancellation. A `.timeLimit` trait cancels the test, but the wait does not stop. Thus a test whose expected update never comes hangs the whole run, and it does not fail. Found in ^zbcrex8: a failing test (a) hung until the process was killed.

## Change

- Make the wait end when its task is cancelled (for example, resume the waiting continuation from a cancellation handler), and make the test fail with a clear message that names the condition that did not come.

## Acceptance

- [x] A test that waits for an update that never comes fails at its time limit, and the run continues.
- [x] A test proves this with a condition that never becomes true and a short time limit (in a `withKnownIssue` block, or by a direct check of the cancelled wait).

#tests

## Review Findings (2026-10-11 08:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> Tool rule 'code-hygiene/dead-code-swift' failed only because it could not remove `.build/checkouts` folders (swift-nio, swift-nio-http2, swift-log, swift-nio-extras: "Operation not permitted"). This failure comes from the checkouts only, thus it does not count.

> The engine found 0 findings. The item below comes from the manual check that the review request asked for.

- [x] `Tests/FoundationModelsACPAgentTests/SinkRecorderTests.swift:84` `manual/test-determinism` — `startWait` yields to `checks` from inside `isComplete`. `WatchedValue.admit` calls `isComplete` under the lock BEFORE it reads `Task.isCancelled` and BEFORE it keeps the wait. Thus `startWait` can return, and the test can call `wait.cancel()`, before the wait is kept. `Task.cancel()` sets the cancel flag before it runs the `onCancel` handler, so `admit` then reads `Task.isCancelled == true` and resumes the wait with its "cancelled before the wait is kept" path. The `onCancel` handler then finds no wait. Thus `aSuspendedWaitForAConditionThatNeverComesEndsWhenItsTaskIsCancelled` does not always prove the path that it names (the `onCancel` handler removes and resumes a kept wait), and the doc comment of `startWait` ("so the wait is then suspended or ended") is not correct at the time that `startWait` returns. Make `startWait` return only after the wait is kept. For example, give `WatchedValue` a count of its kept waits (read under the lock), and make `startWait` wait until that count is 1 before it returns. Then correct the doc comment of `startWait` so that it states the true condition.