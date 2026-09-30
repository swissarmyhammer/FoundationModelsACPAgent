---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3qydt1f9y4kgsb53y25g3gy
  text: |-
    Research done (Extras at 3de1179).
    - `TelemetryCapture.Context.spanPlaces` reads only `operationName` and `attributes`. `FinishedInMemorySpan` also has `events: [SpanEvent]` (name, attributes), `errors: [InMemorySpan.RecordedError]` (error, attributes) and `status: SpanStatus?` (code, message).
    - `InMemorySpan.recordError` adds a `RecordedError` only. It adds no event. Thus the capture must read `errors` itself.
    - `Tracer.withSpan` records the thrown error and sets `SpanStatus(code: .error)` with no message. Thus a thrown error gives one error place and no status place.
    - `SpanAttributes` is not a Sequence. `forEach` is its only walk. The plan: one shared helper collects sorted `(key, text)` pairs for span, event and error attributes.
    - Extras has no CLAUDE.md. `CHANGELOG.md` records each change to the public API, thus the new `TelemetryPlace` cases get an entry.
  timestamp: 2026-09-30T01:21:22.479225+00:00
- actor: claude-code
  id: 01m3qyr52pyyh2s02v4s2f3ra6
  text: |-
    Implementation landed in FoundationModelsExtras as local commit 22a447e (not pushed).
    - Items 1 and 2 are done: `TelemetryCapture.Context.places` now reads, for each span, the name, the attributes, the name and attributes of each event, the description (`String(describing:)`) and attributes of each recorded error, then the status message. New `TelemetryPlace` cases: `spanEventName`, `spanEventAttribute`, `spanError`, `spanErrorAttribute`, `spanStatusMessage`. `SpanAttributes` is still read with `forEach` in one shared helper `texts(of:)`.
    - Acceptance: `aForbiddenRecordedErrorDescriptionIsAnIssue` proves with `withKnownIssue` that a marker in an error description that a span records is an issue. Other new tests prove the same for an event name, an event attribute, an error attribute and a status message.
    - Discovery: the new check found a real case in `TracedCallTests.contentOfTheBodyReachesNoTelemetry`. It threw `ProbeError.carrying(content)` through `TracedCall.run`, and the span records that error. I split the test. The returned-content half still expects no leak. The thrown-error half now proves that the capture finds the leak at `spanError`. The `TracedCall.run` doc comment now tells the caller to throw no error whose description holds content. TracedCall behavior did not change.
    - CHANGELOG.md has an entry for the new `TelemetryPlace` cases (a consumer `switch` must add them).
    - Item 3 WAITS: remove `leaksInSpanDetails(of:)` and its helpers from `TelemetryContentSafetyTests` of FoundationModelsACPAgent only after Extras commit 22a447e is pushed and the pin of this package moves to it. I did not change the FoundationModelsACPAgent sources.
  timestamp: 2026-09-30T01:27:01.462454+00:00
- actor: claude-code
  id: 01m3qyr7s05am37rzdgt319dne
  text: |-
    ### implement — changed
    - evidence: Extras commit 22a447e. Files: CHANGELOG.md, Sources/FoundationModelsExtras/Telemetry/TracedCall.swift, Tests/TelemetryTestSupport/TelemetryCapture.swift, Tests/TelemetryTestSupport/TelemetryPlace.swift, Tests/FoundationModelsExtrasTests/Telemetry/TelemetryCaptureTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/TracedCallTests.swift. Extras `swift test`: 800 tests in 79 suites passed, with 10 expected known issues, 0 failures and 0 compiler warnings.
    - next: review. Item 3 waits until 22a447e is pushed and the pin moves.
  timestamp: 2026-09-30T01:27:04.224068+00:00
- actor: claude-code
  id: 01m3qys83k9pjr3r96s9m2528q
  text: |-
    ### review — stuck
    - evidence: The code of this task is commit 22a447e in the repository /Users/wballard/github/swissarmyhammer/FoundationModelsExtras. That repository has its own root. The review skill permits a review of the repository that holds the working directory only (/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent). The rule does not permit a change of the working directory to a different repository. Thus the engine did not run on 22a447e~1..22a447e. The task stays in doing.
    - next: A person must start the review from a session whose working directory is in FoundationModelsExtras, with `review sha 22a447e~1..22a447e`. Then record the result on this task. Item 3 waits for a push that only the user can do.
  timestamp: 2026-09-30T01:27:37.331480+00:00
- actor: claude-code
  id: 01m3qysmr5vv9bvcjyazhtxn1f
  text: |-
    ### finish iteration 1 — stuck
    - implement: changed — FoundationModelsExtras local commit 22a447e (not pushed); Extras swift test 800 tests pass
    - review: stuck — the review engine reviews only the repository of its working directory. It cannot review 22a447e from the FoundationModelsACPAgent session.
    - next: a session in /Users/wballard/github/swissarmyhammer/FoundationModelsExtras runs /review on 22a447e~1..22a447e, then the commit is pushed, then the pin moves here and item 3 is done.
  timestamp: 2026-09-30T01:27:50.277694+00:00
position_column: doing
position_ordinal: '80'
title: 'Extras TelemetryCapture: read span events, recorded errors and the span status'
---
## What
The `TelemetryCapture` of FoundationModelsExtras (`Tests/TelemetryTestSupport`) reads span names, span attributes, log messages, log metadata values, metric names and metric dimensions. It does not read span events, recorded errors or the span status message. swift-otel exports `span.recordError(error)` as an `exception` event with `exception.message = String(describing: error)`, and `withSpan` and `TracedCall.run` record each error. Thus an error description that holds content leaks, and no family content-safety test catches it through the shared helper.

The work is in the FoundationModelsExtras repository. `TelemetryContentSafetyTests` of this package (^xkm87qd) reads these places itself for now, in `leaksInSpanDetails(of:)`.

- [ ] Add the event name and attributes, the recorded-error description and attributes, and the status message of each span to the places of `TelemetryCapture.Context`.
- [ ] Add a case to `TelemetryPlace` for each new place.
- [ ] After the Extras change lands and the pin moves, remove `leaksInSpanDetails(of:)` and its helpers from `TelemetryContentSafetyTests`.

## Acceptance Criteria
- [ ] A marker in an error description that a span records makes `TelemetryCapture.run(forbidding:)` record an issue.

#otel