---
depends_on:
- 01M6GH2K0VV6RWV5R6SN3HB9SV
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: todo
position_ordinal: '9080'
title: 'Child sessions in usage, telemetry, hooks and the snapshot timeline: same rules as any session'
---
## What
Child sessions must take part in usage, telemetry and hooks like any other session. They are ordinary sessions with a parent (user rule, 2026-11-03: it is just parent and child all the way down). The user does not care who owns this work; this board owns it, because this package builds the wire projection, the telemetry and the hooks of sessions. The review of the plan found no card for it.

Check and fix, in this order (design first; write what is already right and what is missing in a task comment):
1. USAGE. A child reports `usage_update` under its own session id (token counts from its own session). ACP "Subagent Sessions" RFD: the cost of a child is "unknown, not zero", and a client must not add or subtract the costs of a parent and its children. So the agent sends NO cost for a child, and never folds child usage into the usage of the parent. Check `PromptTally` and the usage path in `Sources/FoundationModelsACPAgent/Agent/` so one session never counts the tokens of another.
2. TELEMETRY. Spans, metrics and log metadata of a child carry the child session id and the parent session id. The Router already has the attribute `session.parent_id` (`RouterTelemetry.swift`); check that `ACPAgentTelemetry.sessionMetadata` and `RequestTracing` do the same for the ACP layer. The `activeSessions` gauge (`RoutedACPAgent.swift`, near line 189) counts every non-closed entry in `sessions`: decide whether children count (suggestion: count roots and children in separate attributes, not one number that mixes them).
3. HOOKS. A sub-agent session fires the same hooks as any session, with the right lineage: the Router `SessionHooks` has a sub-agent origin with the key of the parent (`.subagent(sessionID, parentKey)`), and a sub-agent that starts from a restored root gets the key of the root. Check `Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift` and the hook lineage of a child built by the shared session build (task `3HB9SV`), and of a restored child (cold resume).
4. SNAPSHOT TIMELINE. A child shares the snapshot timeline of its folder like its parent (`SnapshotSessionKeys`); check that a child records the right key, and that `session/delete` of the root removes the timelines it should and no others (see the memory rule: `session/delete` removes only its own timeline).
5. Do not change FoundationModelsRouter or FoundationModelsAgents from this task. A needed change there is a card on that board, discussed first.

Depends on: the shared session build (task 1) and the announce task.

## Acceptance Criteria
- [ ] A child sends `usage_update` under its own session id and never includes cost; the parent usage does not include the child tokens.
- [ ] Telemetry of a child carries its session id and its parent session id.
- [ ] The gauge of active sessions does not mix roots and children in one number (or a task comment says why it does).
- [ ] A child fires the hooks of any session, with the lineage key of its root, also after a cold resume.
- [ ] The snapshot timeline of a child is that of its folder, and `session/delete` of the root removes only what it should.
- [ ] A task comment lists which of these already held.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ChildSessionUsageTelemetryHooksTests.swift`: usage per session and no cost, telemetry attributes, gauge, hook lineage, timeline.
- [ ] Run `swift test --filter ChildSessionUsageTelemetryHooksTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents