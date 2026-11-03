---
comments:
- actor: wballard
  id: 01m6gmvg34rqv9sv0ccbhh5qjc
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    A child listed in the parent background list needs a subagent_update BEFORE the parent snapshot (background list rule), and that snapshot is before the response. Send that one pre-response update; the client keeps the child unconfirmed. The post-response snapshot confirms it. Add a hot resume test with a running child. Also announce a child that FAILED to restore as state unknown with a reason (user decision), with no capabilities.
  timestamp: 2026-11-03T12:06:29.732832+00:00
- actor: wballard
  id: 01m6gns7ztr4cq8nas3r5jgxcq
  text: |-
    DECISION (user, 2026-11-03): if an agent session is DONE, there is nothing to restore. When an agent finishes, its session is ended and removed. Agents runs stay ONE-SHOT (no idle state in AgentRunState).
    EFFECT ON THIS PLAN:
    - A resume restores ONLY the sub-agents that were still working (interrupted) when the process stopped. Finished children are not restored and are not announced as part of the restored tree.
    - The set to restore is the set of orphan runs of the parent (a run with a non-terminal journal event and no completed). This is the same set that the Router claim card (01M6GK8K45DRDT6B4SHB9V60ED) lets a host claim. The two tasks are one flow: claim, restore, continue, complete the original call.
    - This replaces: "restore every recorded sub-agent session, found through agentSpawn.parentSessionId, all idle" (cold resume), and "a restored child comes back idle and can get new work later". A restored interrupted child is announced idle in the first snapshot after the response, then goes running when it is continued (re-drive), after the response. It ends once; then it is removed like any finished child.
    - The Agents restore API (card 01M6GNHC0MV9FBT33Z9DTT5TVA on the Agents board, rewritten) restores and continues in one call.
    - To verify first: how the host finds the child session of an orphan run after a crash (orphan RunKey -> SDK tool call id in the journal -> recorded child with agentSpawn.parentToolCallId). The runner map from completion token to run is in memory and is lost in a crash.
    - Open (the user decides): how the live ACP tree tells the client that a finished child is gone. ACP has no removal message; a child stays an idle association.
  timestamp: 2026-11-03T12:22:44.474879+00:00
depends_on:
- 01M6GM0N9BFK37GGBWPAG9VE1X
- 01M6GH30709S58BK3AQ1VMBAM7
- 01M6GH3ZHE52GHWAZ53AWNKJ0K
position_column: todo
position_ordinal: '8e80'
title: Resume announces the children and sends their current snapshots after the response, with or without replayFrom
---
## What
ACP "Subagent Sessions" RFD, resume rules for children:
- Children are announced (`subagent_update`) before any use of a child in live traffic, in parent-before-child order (the complete ancestor chain), also for a routing-only ancestor that was not restored (an association establishes identity, not a live runtime).
- With a replay: all history selected for the replay (associations and child history) is sent BEFORE the response. The response completes the best-effort child replay. The response is the freshness boundary: child work-state and capability snapshots sent before it are historical; CURRENT snapshots are sent AFTER the response.
- Without a replay: announcements, current snapshots and ordinary child traffic may come before or after the response, subject to announcement ordering.
- Agents SHOULD report the current child work state when they can determine it. Replay MUST NOT reissue permission or elicitation requests.
- A child state mirror on the parent (`subagent_update.state`) and the child own `state_update` must keep order: a delayed copy never overwrites a newer state.

Do (in the resume path of `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`, after the shared child build of the first task):
1. After the response, send one current `subagent_update` for each child of the tree (state, capabilities, cwd) and, for a child that has its own session, its own current `state_update`. Cold-restored children: `idle`. Live children (hot resume): their real state.
2. The post-response sends happen before any re-drive and before any other live traffic of the same child.
3. With no `replayFrom`, still announce the children and send the snapshots (parent first).
4. Children are in the `background` list of their parent while running (background list task).
5. Do not change FoundationModelsACP or the client from this task.

## Acceptance Criteria
- [ ] With a replay: no child current snapshot before the response; every child has a current snapshot after it; each parent is announced before its child.
- [ ] Without a replay: children are announced and snapshotted, parent first.
- [ ] A live running child (hot resume) shows `running` in its snapshot, not `idle`.
- [ ] A snapshot of a child precedes any later `running` update of the same child.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ResumeChildSyncTests.swift`: order with and without a cursor, a chain of three sessions, hot and cold, snapshot before re-drive.
- [ ] Run `swift test --filter ResumeChildSyncTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents