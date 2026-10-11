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
position_column: doing
position_ordinal: '80'
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