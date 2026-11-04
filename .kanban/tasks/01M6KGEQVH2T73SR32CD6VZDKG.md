---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: Orderly shutdown pauses the open tool calls and does not cancel them
---
## What
An orderly shutdown (SIGTERM, `agent.shutdown()`) must not cancel the open root prompt. Today `tearDownSession` in `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift` calls `entry.session.cancelAll()` and `waitForPromptEnd()` first, also when `isShutdown` is true. The root `agents` call then gets the final status `cancelled` in the history. After a resume, rule 1 of ^7wta3jt does not restore a child whose call is final, so an orderly shutdown restores no child. Only a hard kill restores an interrupted child.

Found by the implement step of ^7wta3jt (a `cancelled` tool_call_update for the root `agents` call was seen during `agent.shutdown()`).

## Decision source
Relayed by the peer session foundationmodelsacpagent-9b from its user, after it read Schema/acp-v2.unstable.json:
- `ToolCallStatus` has `paused`: the call has started, is not running now, and does not continue until something resumes it. It may return to `in_progress`. It is not final. `SessionMergeEngine` already treats `.paused` as not terminal, so validator rule 8 does not fire for a paused call.
- `session/close` (CloseSessionRequest): the agent MUST cancel ongoing work as if `session/cancel` was called, send the final updates and the idle `state_update` with stopReason `cancelled`, then respond. So `session/close` and `session/delete` KEEP cancelling. Do not change them.
- An orderly shutdown is not a `session/close` request. The spec says nothing about process shutdown.

## Do
Change `tearDownSession` for the `isShutdown` path only:
1. On shutdown, do not call `cancelAll()` on the open root prompt. Suspend the sessions (the agent runs are already suspended).
2. The open tool calls of the root and of each running child (the `agents` call at least) get a `tool_call_update` with status `paused`, not `cancelled`. The history then holds no final status for them. Check the translator for a way to send the update before the connection closes, and that the history records it.
3. On resume, a paused call is not final, so rule 1 of ^7wta3jt restores its child. When the child is re-driven, the call returns to `in_progress`.
4. Settle one open point on this card (ask the peer session if it is not clear): how the interrupted prompt of the root looks after a resume. The `state_update` snapshot after a resume must not report a completed prompt for the root.
5. Do not change a sibling package.

## Acceptance Criteria
- [ ] After `agent.shutdown()` with an open root prompt, the history holds the `agents` call with status `paused`, and no `cancelled` status.
- [ ] After a resume with replay, the interrupted child is restored, and the wire passes `SubagentWireTraceValidator`.
- [ ] `session/close` and `session/delete` still cancel the open work with a final `cancelled` status.
- [ ] The root does not report a completed prompt after the resume.

## Tests
- [ ] A test with the REAL shutdown path: `agent.shutdown()`, then resume with replay. It checks that the call is `paused` in the history and that the child is restored.
- [ ] A test that `session/close` still cancels.
- [ ] Run `swift test` for the touched suites, then the full suite. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents