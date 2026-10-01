---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3vrgzmygzwaj0gek5ehtxak
  text: 'Added scope from the verifier of Extras b9447b2: `Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift:61` (`withSpan(tracer:toolName:sessionID:runKind:_:)`) has the same leak. Each mounted tool call goes through it (BackgroundToolRunner, RunToCompletionRunner, ContextBindingTool), and the tool error description goes to the backend as `exception.message`. Its type doc says "no tool arguments and no tool output", which is false for a tool that throws such an error. Fix it with the same safe error record (type name only) as `TracedCall.run`, and add a content-safety test for one runner with a tool that throws an error with content.'
  timestamp: 2026-10-01T12:55:12.798158+00:00
- actor: claude-code
  id: 01m3vs7m7k5m1crap88kwvtkhe
  text: |-
    Implementation landed as Extras local commit b837e56 (parent a306b78, not pushed).
    - `TracedCall.run`: the closure that it gives to `withSpan` catches the error of the body, sets `SpanStatus(code: .error)` and `error.type`, and gives the error back as a `Result`. Thus `withSpan` sees no error and calls no `recordError`. `run` then throws the same error. No `String(describing: error)` and no `recordError(error)` remain in Extras Sources.
    - `ExtrasTelemetry.AttributeKey.errorType = "error.type"`. `ExtrasTelemetry.errorType(of:)` gives `String(reflecting: type(of: error))`, then `.` and the enum case name when `Mirror` shows a case label. Limit: reflection shows no label for an enum case with no payload, thus that value is the type name only. This is the same `Mirror` method as `ACPAgentTelemetry.caseName(of:)`.
    - Other span error paths in Extras Sources: only `TracedCall.run`. `ToolCallSpan.withSpan` (thus BackgroundToolRunner, RunToCompletionRunner and ContextBindingTool) goes through it. No other `withSpan`, `startSpan` or `recordError` call is in Extras Sources.
    - Tests: `TracedCallTests.contentOfTheBodyReachesNoTelemetry` has one claim again (a thrown error with content reaches no telemetry; the span has the error status and `error.type` = `<ProbeError>.carrying`). New `ExtrasContentSafetyTests.aThrowingCallCarriesNoContent`: a run-to-completion tool that throws an error with the argument and the output in its description. `aThrownErrorSetsTheErrorStatusAndIsRethrown`, `aBodyThatNeverReturnsLeavesItsEnterRecord` and `ToolCallSpanTests.anErrorSetsTheErrorStatusAndIsThrown` now read the status and `error.type` in place of `span.errors`. Each new and changed test failed before the change.
    - Docs: `TracedCall` type doc, `run` doc and `Throws:`, the `ToolCallSpan` type doc and `withSpan` `Throws:`, and CHANGELOG.md (`### Changed (breaking): TracedCall.run records the error type on the span, never the error description`). The commit is `fix(telemetry)!:` with a `BREAKING CHANGE:` footer, because a consumer that reads `span.errors` of such a span breaks.
    - Discovery (agent side, not changed here): `RequestTracing.endRequestSpan(_:throwing:)` of the agent calls `span.recordError(error)` itself, which is the same leak. `AgentSpanTests` expects `commandSpan.errors.count == 1` and `connectSpan.errors.count == 1`; these become 0 when the pin moves to b837e56. New card ^p65xapf holds this work.
  timestamp: 2026-10-01T13:07:34.771924+00:00
- actor: claude-code
  id: 01m3vs7qzf508v4ns6dr90se2p
  text: |-
    ### implement — changed
    - evidence: Extras commit b837e56 (parent a306b78). Files: CHANGELOG.md, Sources/FoundationModelsExtras/Telemetry/TracedCall.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift, Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/ExtrasContentSafetyTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/ExtrasTelemetryTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift. Extras `swift test` at b837e56: 862 tests in 83 suites passed, 11 known issues, 0 failures, 0 compiler warnings from Extras sources.
    - next: review of b837e56~1..b837e56 from a session in FoundationModelsExtras, then the user pushes a306b78 and b837e56. The agent follow-up is card ^p65xapf.
  timestamp: 2026-10-01T13:07:38.607532+00:00
- actor: claude-code
  id: 01m3vsmjapcmzd98rxze3b2t79
  text: |-
    ### implement — changed
    - evidence: two verifier findings are fixed with a fixup and an autosquash rebase. Extras b837e56 is now 50fd4a5 (parent cdfe98d), with the same message. Files: Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift (`errorType(of:)` gives the type name only for a `CustomReflectable` error), Tests/FoundationModelsExtrasTests/Telemetry/ExtrasTelemetryTests.swift (4 new tests), CHANGELOG.md. TDD: the CustomReflectable test failed first with `...CustomError./secret/path`, then passed. Full Extras `swift test`: 866 tests in 83 suites passed, 0 failures, 11 known issues (these existed before). No warning comes from Extras sources.
    - discovery: `Mirror(reflecting:)` always uses `customMirror` when the type has one. Thus the `.enum` display style alone does not prove that the child label is a case name.
    - next: review. Nothing is pushed. Card ^tcp65xapf names b837e56 as the pin target, and the new sha is 50fd4a5.
  timestamp: 2026-10-01T13:14:38.806336+00:00
- actor: claude-code
  id: 01m3vsv7jb8mzzz4n6n2kcj7ny
  text: |-
    ### review — clean
    - evidence: double-check verifier PASS on Extras 50fd4a5. All three earlier findings are fixed. No other span error path in Extras Sources. Filtered telemetry tests: 48 pass.
    - next: done. Push Extras, then move this repo's pin (^p65xapf).
  timestamp: 2026-10-01T13:18:17.163798+00:00
depends_on:
- 01M3QXC37PHQ3Z4KHQARCY24ZJ
position_column: done
position_ordinal: ff8980
title: 'Extras TracedCall: record only the error type on the span, never the error description'
---
## Why
Extras commit 22a447e (card ^rcy24zj) made `TelemetryCapture` read recorded errors. It found a real leak: `TracedCall.run` records the thrown error on its span with `span.recordError(error)`, and swift-otel exports `exception.message = String(describing: error)`. An error description can hold content (a path, a prompt fragment, a tool argument). Commit 22a447e only added a doc comment that tells the caller not to throw such an error. A rule in a doc comment does not protect the telemetry.

## What (in the FoundationModelsExtras repository)
- [x] `TracedCall.run` records the error without its description: set the span status to error, and set `error.type` to the type name (and the case name for an enum), in the same way as this agent's `RequestTracing` does. Do not call `recordError(error)` with the raw error. (Extras 50fd4a5)
- [x] Change `TracedCallTests.contentOfTheBodyReachesNoTelemetry` back to one claim: a thrown error that holds content reaches no telemetry. (Extras 50fd4a5)
- [x] Check the other `recordError` calls in Extras for the same cause. (No other call; `ToolCallSpan.withSpan` goes through `TracedCall.run`.)
- [x] Update the doc comment and CHANGELOG.md. (Extras 50fd4a5)

## Acceptance Criteria
- [x] A marker in the description of an error that `TracedCall.run` throws makes `TelemetryCapture.run(forbidding:)` record no issue, and the span still has the error status and `error.type`. (ExtrasContentSafetyTests, TracedCallTests)

## Review Findings (2026-10-01 verifier)
- [x] Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift `errorType(of:)`: `Mirror(reflecting:)` uses a `customMirror`, so a `CustomReflectable` error can put payload text into the case label (proved: `Custom.missing("/secret/path")` gives `mirror.Custom./secret/path`). Use the case label only when the error is NOT `CustomReflectable` and the mirror is `.enum`; otherwise give the type name only. Add unit tests of `errorType(of:)`: a CustomReflectable enum error whose label is the payload (type name only), a payload enum case, a case with no payload, and a struct error. Fixed in Extras 50fd4a5: a guard gives the type name only for a `CustomReflectable` error; four new tests in ExtrasTelemetryTests (the CustomReflectable test failed first with `...CustomError./secret/path`, then passed).
- [x] CHANGELOG.md, the a306b78 TelemetryCapture entry under `## Unreleased` (the "Behavior change." and "Cause." paragraphs) still say TracedCall.run records the error at spanError. After b837e56 that is false. Make those sentences name only `withSpan` (the swift-distributed-tracing helper), and add that `TracedCall.run` records no error (see the entry above). Fixed in Extras 50fd4a5. The TracedCall entry also states that the `error.type` value of a `CustomReflectable` error is the type name only.

#otel #upstream