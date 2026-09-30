---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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