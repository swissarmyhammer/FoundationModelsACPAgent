---
assignees:
- claude-code
position_column: doing
position_ordinal: '8780'
title: 'Process quit (stdin close or SIGTERM) with an open root prompt cancels the prompt and the child: pause them instead'
---
## What
Found by the implement step of ^C0991F (real binaries, integration test `RedriveInterruptedRunsProcessTests`). Task ^d6vzdkg made an orderly `agent.shutdown()` pause the open tool calls and not cancel them. The real process does not follow that rule in two cases:
- A quit by stdin close or SIGTERM while a root prompt is open cancels the prompt and the child. The child then ends as `finished` and is not restorable.
- A quit while the root has no open prompt cancels the child after the run grace (about 5 s).

Only a SIGKILL leaves an interrupted child that a cold resume can re-drive.

## Do
1. Reproduce with the real binary (`acp-agent-launcher` / `acp-agent-stub`, see `IntegrationTests/.../RedriveInterruptedRunsProcessTests.swift` and `SpawnedACPAgent.killAndWait`): start a nested run, then close stdin, then SIGTERM. Find which path the process takes (for example `ComposedAgent.shutdownAfterConnectionTeardown()`, `closeSessions(where:isShutdown:)`, the connection-teardown path, the run grace in AgentRunHost) and why it does not reach the `isShutdown` pause of ^d6vzdkg (`SessionShutdownPause.swift`, `tearDownSession`).
2. Make an orderly process quit pause the open tool calls of the root and of each running child, and suspend the agent runs without cancelling them, in both cases above. `session/close` and `session/delete` keep cancelling.
3. Do not change a sibling package. If the Agents package cancels the child by itself on a run-host stop (the run grace), say which API a change needs and mark the task stuck.

## Acceptance Criteria
- [ ] After a stdin close with an open root prompt, a cold resume restores the child and re-drives it (integration test with real binaries).
- [ ] After a SIGTERM with an open root prompt, the same.
- [ ] After a quit with no open root prompt, the child is not cancelled by the run grace, and a cold resume re-drives it.
- [ ] `session/close` and `session/delete` still cancel.

## Tests
- [ ] Integration tests with real binaries for the three quits.
- [ ] Run the full `swift test`. All pass.

## Workflow
- Use `/tdd`. #subagents