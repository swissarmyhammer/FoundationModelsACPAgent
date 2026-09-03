---
assignees:
- claude-code
position_column: todo
position_ordinal: a480
title: Project the new SessionEvent cases toolCallReport and elicitationRequested to the wire
---
## What
The FoundationModelsRouter update (revision `ba55154`) adds two `SessionEvent` cases:

- `toolCallReport(ToolCallReport)` — the records one tool call attached, keyed by the run's `correlationID` (its `completionToken`). At least one attachment.
- `elicitationRequested(OperationEvent)` — a run asked the user a question through `ToolContext.elicit(_:)` and is suspended until a host answers through `RoutedSession.respond(elicitationId:response:)` or `complete(elicitationId:)`.

`EventProjection.project(_:)` in `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift` now absorbs both cases with log-only arms, so the stream does not break. That is a degradation, not a projection.

## Work
- [ ] Decide the wire mapping for `toolCallReport` attachments (plan.md §8.4's vocabulary; possibly `tool_call_update` content items keyed by the run's `correlationID`).
- [ ] Decide the wire mapping for `elicitationRequested` — ACP has a permission/elicitation surface; the answer path needs `RoutedSession.respond(elicitationId:response:)`.
- [ ] Replace the two log-only arms with the real projections and tests.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.