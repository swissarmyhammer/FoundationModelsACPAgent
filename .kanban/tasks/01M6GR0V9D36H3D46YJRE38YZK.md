---
comments:
- actor: claude-code
  id: 01m6j5gjwabyh0tdrsmg3xdxy4
  text: |-
    ### Design check: what held before, what was missing

    HELD BEFORE this task:
    - Gauge of active sessions: `recordActiveSessions` counts only non-closed sessions with no parent. Children are not in the number, so roots and children never mix. Decision: keep one gauge for roots. The root count is the count that a client opened. A child starts and ends by its own run, and a mixed number would change with each run. A test pins this.
    - Hooks of a child: Router gives a sub-agent the origin `.subagent`, the key of its parent, and the parent id and root id. Tests pin it for a fresh child. After a cold resume, the restored child has the key of the folder and the root as parent (also pinned).
    - Parent usage holds no child tokens: each session has its own projector and its own prompt tally. A test pins this.
    - `session/delete` of the root: `tearDownSession` retires the children first, so they leave the table before the timeline check. Only the timeline of the folder key is removed, and only when no other session uses it. No sweep was added (memory rule kept).

    MISSING, now fixed:
    1. USAGE. A child run has no prompt, so its tokens went to a scratch tally and no `usage_update` was sent for a child. Now `ProjectionState.runTally` counts the events that belong to no open prompt, and the end of the run (`SessionProjector.end(with:)`) sends one `usage_update` before the `idle`. It has the context of the last submission of this session only, and no cost (the cost stays `unchanged`: unknown, not zero).
    2. TELEMETRY. The ACP layer had no parent id. Added `session.parent_id` (attribute key and log metadata key, the same name as Router). `ACPAgentTelemetry.sessionMetadata`, `modelMetadata` and `errorMetadata` take `parent:`. `RequestTracing` span entry points take `parentSessionId`; `session/prompt` and `session/cancel` pass the parent from `sessionTree`. `ACPEventTranslator`, `ElicitationRelay`, `PromptExecution` and `SessionProjector` carry the parent id for their log records. Metrics have no session id dimension (the existing rule), so metrics are unchanged.
    3. SNAPSHOT KEY. A fresh child had no entry in `SnapshotSessionKeys` (only a restored child had one), so the `snapshots` tool of a fresh child found no key. `registerNestedSession` now records the key of the parent (or the folder key) for the child, before the registration, and `retireSession` forgets the key of the child. The record in `registerRestoredRun` was removed: one place records the key for every nested session. `restoreNestedSessions` lost its `hookLineage` parameter.

    Test-only change: `ResumeNestedSessionsTests` made `Recording`, `recordInterruptedChain` and `resumeRoot` internal, so the new suite reuses the cold-resume fixture.

    Tests: `ChildSessionUsageTelemetryHooksTests` (23 tests). RED first: 5 usage tests and the live-child key test failed; the telemetry tests did not compile. GREEN after the change. Filtered run of 15 related suites (221 tests) passes.
  timestamp: 2026-11-04T02:16:52.362718+00:00
- actor: claude-code
  id: 01m6j5gsfjmq25bazc83scb0qd
  text: |-
    ### implement — changed
    - evidence: 15 files. Sources: Agent/ACPEventTranslator.swift, Agent/ElicitationRelay.swift, Agent/PromptExecution.swift, Agent/SessionBuild.swift, Agent/SessionProjector.swift, Agent/SessionResume.swift, Agent/SessionResumeNested.swift, Telemetry/ACPAgentTelemetry.swift, Telemetry/RequestTracing.swift. Tests: ChildSessionUsageTelemetryHooksTests.swift (new, 23 tests), ResumeNestedSessionsTests.swift (access change). All 8 acceptance and test items are checked. `swift test --filter ChildSessionUsageTelemetryHooksTests`: 23 passed. Filtered run of 15 related suites: 221 passed.
    - next: /review
  timestamp: 2026-11-04T02:16:59.122622+00:00
- actor: claude-code
  id: 01m6j5wn5s4m26czcq0nnxhmn7
  text: |-
    ### review — findings
    - scope: review sha HEAD~1..HEAD
    - evidence: 1 finding, 1 confirmed, 5 refuted. Tests/FoundationModelsACPAgentTests/ChildSessionUsageTelemetryHooksTests.swift:302
    - finding: The helper announcedChild(in:on:) copies an existing helper with the same name and signature. Delete the copy and call the existing helper. Widen the access of the existing helper, or move it to the Support folder.
    - next: Fix the finding. Task stays in review.
  timestamp: 2026-11-04T02:23:27.929868+00:00
- actor: claude-code
  id: 01m6j5wyr0qc80af9d7crae8f2
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 15 files, 8 of 8 items checked
    - test: red — root 1557 tests, only the known blocker ShellSessionOwnerTests (card ^wd0cwz7) failed; IntegrationTests deterministic 38 passed
    - commit: 9c3f8ad
    - review: findings — Tests/FoundationModelsACPAgentTests/ChildSessionUsageTelemetryHooksTests.swift:302
    - next: implement works the 1 open finding
  timestamp: 2026-11-04T02:23:37.728813+00:00
- actor: claude-code
  id: 01m6j5yq7zgspk1qfqzr3ftg8n
  text: |-
    ### implement — changed
    - evidence: 4 files changed, 1 added. Finding checked: ChildSessionUsageTelemetryHooksTests.swift:302 (copy of announcedChild). The shared helper AnnouncedChild.first is now in Tests/FoundationModelsACPAgentTests/Support/AnnouncedChild.swift. ResumeNestedSessionsTests and the new suite both call it. Same cause removed from the whole file: the copies of isFinal and agentsCall in the new suite are deleted; it calls ChildSessionProjectionTests.isFinal and agentsCall (agentsCall widened from private). Filtered tests: 43 tests in 3 suites passed.
    - next: review
  timestamp: 2026-11-04T02:24:35.583408+00:00
depends_on:
- 01M6GH2K0VV6RWV5R6SN3HB9SV
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: review
position_ordinal: '80'
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
- [x] A child sends `usage_update` under its own session id and never includes cost; the parent usage does not include the child tokens.
- [x] Telemetry of a child carries its session id and its parent session id.
- [x] The gauge of active sessions does not mix roots and children in one number (or a task comment says why it does).
- [x] A child fires the hooks of any session, with the lineage key of its root, also after a cold resume.
- [x] The snapshot timeline of a child is that of its folder, and `session/delete` of the root removes only what it should.
- [x] A task comment lists which of these already held.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ChildSessionUsageTelemetryHooksTests.swift`: usage per session and no cost, telemetry attributes, gauge, hook lineage, timeline.
- [x] Run `swift test --filter ChildSessionUsageTelemetryHooksTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-03 20:19)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/ChildSessionUsageTelemetryHooksTests.swift:302` `reuse/reuse` — The new `announcedChild(in:on:)` helper repeats the body of an existing helper with the same name and signature. Two copies of one test helper will drift apart when the announcement shape changes. Delete the copy in ChildSessionUsageTelemetryHooksTests.swift and call the existing helper. Its `private` modifier must be widened (for example to `static`, or moved to a shared test support file such as the `Support/` folder) so both suites can use it.
