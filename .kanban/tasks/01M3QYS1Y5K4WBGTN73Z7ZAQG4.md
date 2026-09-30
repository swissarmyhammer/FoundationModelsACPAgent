---
assignees:
- claude-code
depends_on:
- 01M3QXC37PHQ3Z4KHQARCY24ZJ
position_column: todo
position_ordinal: '8180'
title: 'Extras TracedCall: record only the error type on the span, never the error description'
---
## Why
Extras commit 22a447e (card ^rcy24zj) made `TelemetryCapture` read recorded errors. It found a real leak: `TracedCall.run` records the thrown error on its span with `span.recordError(error)`, and swift-otel exports `exception.message = String(describing: error)`. An error description can hold content (a path, a prompt fragment, a tool argument). Commit 22a447e only added a doc comment that tells the caller not to throw such an error. A rule in a doc comment does not protect the telemetry.

## What (in the FoundationModelsExtras repository)
- [ ] `TracedCall.run` records the error without its description: set the span status to error, and set `error.type` to the type name (and the case name for an enum), in the same way as this agent's `RequestTracing` does. Do not call `recordError(error)` with the raw error.
- [ ] Change `TracedCallTests.contentOfTheBodyReachesNoTelemetry` back to one claim: a thrown error that holds content reaches no telemetry.
- [ ] Check the other `recordError` calls in Extras for the same cause.
- [ ] Update the doc comment and CHANGELOG.md.

## Acceptance Criteria
- [ ] A marker in the description of an error that `TracedCall.run` throws makes `TelemetryCapture.run(forbidding:)` record no issue, and the span still has the error status and `error.type`.

Decision: the owner of this board decided this (no content in telemetry). #otel #upstream