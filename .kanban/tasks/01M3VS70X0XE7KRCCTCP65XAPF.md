---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3vsn4zprhwf83as84023cx4
  text: 'Correction: the Extras commits were rebased and fixed. The pin target is now Extras 50fd4a5 (was b837e56); its parent cdfe98d (was a306b78) holds the TelemetryCapture change of ^rcy24zj.'
  timestamp: 2026-10-01T13:14:57.910273+00:00
depends_on:
- 01M3QYS1Y5K4WBGTN73Z7ZAQG4
position_column: todo
position_ordinal: '9880'
title: 'After the Extras pin moves to b837e56: adopt the safe error record of TracedCall.run in the agent'
---
## Why
Extras commit b837e56 (card ^z7zaqg4) changes `TracedCall.run`. When the body throws, the span gets the error status and `error.type` only. The span records no error with `recordError`, because swift-otel exports the error description as `exception.message`, and a description can hold content.

The agent has two items that this change touches:
- `RequestTracing.endRequestSpan(_:throwing:)` calls `span.recordError(error)` itself. This is the same leak as the one that b837e56 removes from Extras.
- `AgentSpanTests` expects `commandSpan.errors.count == 1` and `connectSpan.errors.count == 1`. These spans go through `TracedCall.run`, thus the count becomes 0 when the pin moves.

## What
- [ ] Move the Extras pin to b837e56 or later (after the user pushes it).
- [ ] `RequestTracing.endRequestSpan(_:throwing:)`: set the error status and `error.type` only. Do not call `recordError(error)`.
- [ ] `AgentSpanTests` and `RequestTracingTests`: read the error status and `error.type` in place of `span.errors`.
- [ ] `AgentTracing.recordingErrorType` writes `error.type` as the type name only. Extras `TracedCall.run` now writes the same key, with the enum case name when reflection shows one, after the body ends. Decide if the agent keeps its own write or uses the Extras value.
- [ ] Remove `leaksInSpanDetails(of:)` from `TelemetryContentSafetyTests` (item 3 of ^rcy24zj).

## Acceptance Criteria
- [ ] A request, command or MCP connect error whose description holds content reaches no span, log record or metric, and `TelemetryCapture.run(forbidding:)` proves it.

#otel