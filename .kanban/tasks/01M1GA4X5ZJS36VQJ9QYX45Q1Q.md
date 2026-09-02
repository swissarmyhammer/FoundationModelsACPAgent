---
assignees:
- claude-code
position_column: todo
position_ordinal: a080
title: Forward a nested background run's settlement to the wire
---
## What
The tier-2 streamed-shell proof (task ^qg1rfct) found this gap: a nested background run — `tools.shell.execute` started inside a `runCode` snippet — never gets a `runSettled` event on the session stream. The run completes, `wait` collects its result, the terminal stream reports the exit, but no terminal `tool_call_update` with `status: completed` reaches the client. The call stays `in_progress` in `ACPSessionState.toolCalls` forever.

The outer `runCode` run's own settlement DOES reach the wire, so the forwarding works for runs the turn's context starts directly. Only the nested run's terminal event is lost.

## Why
Plan.md §8.4 maps `runSettled(OperationEvent)` to the terminal `tool_call_update`, and §11.6 wants the settlement replace as the convergence step. A client that shows the run as still running after it ended is wrong.

## How
- Trace where a nested run's terminal `OperationEvent` goes in Router's context forks (`ToolContext` mailbox and outbox).
- Decide with the Router or Multitool owners whether the fix is upstream (forward nested run events to the session outbox) or in this package.
- Then restore the `completed` status assertion in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` proof 7 (see the comment in `aStreamedShellRunRidesTheTerminalStreamAndConverges`).

## Acceptance Criteria
- [ ] A nested shell run's terminal `tool_call_update` with `status: completed` reaches the client before or after the turn end
- [ ] Tier-2 proof 7 asserts `ACPSessionState.toolCalls[id].status == completed` and stays green