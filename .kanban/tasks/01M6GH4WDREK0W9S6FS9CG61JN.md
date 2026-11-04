---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gmvgfepp84ky8paym1vy52
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    This task is stale: do not create SubagentSessionTable or SubagentProjector (design rule: one code path for all sessions). The client package now has a card. Rewrite to: the real acp-agent binary and the client over the wire; criteria: cold resume order (replay, background updates, state_update, session info, response, then child snapshots), hot resume, cancel of one child, session/list shows only the root. Depends on the resume cards.
  timestamp: 2026-11-03T12:06:30.126099+00:00
- actor: claude-code
  id: 01m6kyenxetr33ezj1ge1r1cfc
  text: |-
    ### implement — changed
    - commit: 5a4333b on branch wt-e2edocs (worktree /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent-wt-e2edocs). Not pushed, not merged.
    - files: IntegrationTests/.../SubagentSessionsTests.swift (new, 5 tests), Support/NestedRootSession.swift, Support/NestedAgentFixture.swift, Support/LiveTraceReading.swift (new), RedriveInterruptedRunsProcessTests.swift (now uses the shared support, no copy of the helpers), README.md, ARCHITECTURE.md.
    - build proof: `swift build --build-tests --package-path IntegrationTests` from a scratch copy named FoundationModelsACPAgent: Build complete, no warning in the new files. The IntegrationTests package was NOT run (user rule). No unit test was added: the unit level already covers each criterion in process (SubagentSessionsReplayTests, SubagentCancelTests, SessionCapabilityTests, HotResumeTests, ResumeChildSyncTests, ProcessQuitShutdownTests, RedriveInterruptedRunsTests), and the new code is test support only. The root `swift test` was not run: no root source changed.
    - tests (CI only): theChainIsAnnouncedParentFirstAndGoesIdleFromTheLeafUp (child announcement, grandchild announcement, events under each id, idle leaf then child then root); theWireOfTheChainFollowsTheRulesOfTheValidator (SubagentWireTraceValidator over the live trace); sessionListShowsOnlyTheRootSession; aChildSessionRefusesPromptAndClose; cancelOfTheChildEndsTheChildAndLeavesTheRoot (idle cancelled for child and grandchild, no cancelled idle for root); aColdResumeReplaysTheChainParentFirstAndRestoresTheRunsAfterTheResponse (two processes, orderly quit by closed stdin, replayFrom start, history before response, snapshot and re-drive after, validator clean).
    - boxes ticked: docs (ARCHITECTURE.md + README.md), and the existence of SubagentSessionsTests. Left open, only CI can prove them: the four wire criteria, the IntegrationTests run, the root swift test run.
    - Card correction (comment 01m6gmvgfepp84ky8paym1vy52) followed: no SubagentSessionTable or SubagentProjector was created. ARCHITECTURE.md names the real components (SessionTree, SessionCapabilitySet, SubagentAnnouncer, SubagentMessageProjector, SessionShutdownPause, SessionResume*).
    - comments of RunCallJoinTable and AgentsComposition: already correct in main (they say the child projector sends the updates and the observer sends nothing itself); no edit needed.
    - client package finding: not tested here beyond what the test shows in CI. The test reads all sessions with `subscribeToAllSessions()` and uses ConnectionModel only for initialize/new session; a child id that ConnectionModel/SessionModel drops would not fail this test, because the test reads the raw wire stream. No client change was made.
    - risks for CI: (1) the cancel test must cancel before the 6 s inline settle grace ends, or the grandchild is no longer waited for inline. The test cancels as soon as the grandchild plays its text. (2) the cold resume test relies on the stub gate ending when the shutdown stops the run, and on the closed-stdin quit (ProcessQuit path) pausing, not cancelling. (3) the second-process script gives one entry for the restored message; all restored runs play the same text.
    - next: /test (CI for the integration package), then /review.
  timestamp: 2026-11-04T18:51:58.766319+00:00
- actor: claude-code
  id: 01m6kywtxxd8vtqbmajf0sz8fq
  text: |-
    ### review — findings
    - evidence: review sha 4906c02~1..4906c02. 11 findings, 11 confirmed, 7 refuted, 0 failed (run complete). ARCHITECTURE.md and README.md had no matching validator, so I checked them by hand against the code.
    - doc check: No wrong statement found. Checked: all named types exist; shutdown order (suspend, pause, stop, close) and stop reason _interrupted; paused status only for in_progress calls; capability set (root permits all, child permits cancel only); refusal is invalid params with sessionId, method, reason in data; checks in prompt, close, delete, resume, set_config_option; cancel on a non-permitting session is ignored; hot resume take rules (userDevice, external, SESSION_HAS_OWNER); cold resume snapshot (idle child, restoreFailure in _meta.sah, no state, no capabilities); re-drive after snapshots, children before callers, first message text in FoundationModelsAgents; stub script keys (gate with file or named pipe, elicit needs runCode). Not proven by a test I could find: the final status cancelled on the open agents call of the root at user session/close, and that session/list leaves out the child (comes from the Router store).
    - open boxes (CI only, by design): the four wire criteria, the IntegrationTests run, the root swift test.
    - next: the implementer resolves the 11 findings; then run /review again.
  timestamp: 2026-11-04T18:59:42.653220+00:00
- actor: claude-code
  id: 01m6kz67matfn54jw1vj3zg1h1
  text: |-
    ### implement — changed
    - evidence: the 11 findings are fixed and ticked. Build: `swift build --build-tests --package-path IntegrationTests` complete, no warning; root `swift build --build-tests` complete. Unit suite SessionCapabilityTests run once: 15 tests passed. IntegrationTests package not run (CI only).
    - teardown: NestedRootSession.closeClientSide() (cancel prompt, close connection); used by quit and recordInterruptedRun.
    - gate path: NestedAgentFixture.gateFile(label:); used by both suites.
    - chain lookup: [WireTraceEvent].chain(of:) -> (child, leaf)?; used by leafIsWorking, runFinishedChain, and NestedChain.init.
    - one result struct: NestedChain replaces FinishedChain and WorkingChain.
    - refusals: new shared helpers in Tests/FoundationModelsACPAgentTestSupport/MethodRefusalReading.swift: requestErrorThrown(by:) and isMethodRefusal(_:of:on:). They check code invalidParams, the standard message, and data sessionId, method and reason ("the session X does not permit M"), the error of methodNotPermitted. SessionCapabilityTests now use them (private copies removed). SubagentSessionsTests asserts session/prompt and session/close on the child with them. A transport error or crash gives nil and fails the check.
    - resume driver: NestedAgentFixture.resumeTrace(of:workspace:configHome:script:label:replayFrom:settledBy:timeout:); both suites call it.
    - idle pair: one isIdle(of:stopReason:) (nil = any); isCancelledIdle removed.
    - isCompletedCall: now uses the stream and sessionUpdate accessors.
    - spawn/connect/initialize: new Support/ConnectedAgent.swift; NestedRootSession.start and resumeTrace call it.
    - files: IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/{SubagentSessionsTests,RedriveInterruptedRunsProcessTests}.swift, Support/{ConnectedAgent,LiveTraceReading,NestedAgentFixture,NestedRootSession}.swift, Tests/FoundationModelsACPAgentTestSupport/MethodRefusalReading.swift, Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift.
    - next: /review again.
  timestamp: 2026-11-04T19:04:50.570759+00:00
- actor: claude-code
  id: 01m6kzdqhdgypsh73xbk9nxnss
  text: |-
    ### review — findings
    - evidence: review sha 4906c02~1..6510361; counts findings 1, confirmed 1, refuted 0, failed 0; IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/NestedRootSession.swift:48
    - next: fix the swallowed prompt result, then review again. Boxes that only CI can prove stay open by design.
  timestamp: 2026-11-04T19:08:56.237686+00:00
- actor: claude-code
  id: 01m6kzk1t7t1sxawcg7dqnqanq
  text: |-
    ### implement — changed
    - finding fixed: NestedRootSession.closeClientSide() now cancels the prompt, closes the connection, then reads `prompt.result`. An error that is not expected is recorded with Issue.record, so the test fails.
    - accepted set (from the SDK code in FoundationModelsACP Connection.swift): success; CancellationError (prompt.cancel() runs cancelOutbound, which fails the pending request with it); ConnectionError.closed (shutDown rejects every pending request with it on EOF after kill or end of the agent, on transport failure, and on close()). Rejected: RequestError (peer error), ConnectionError.timedOut, all others.
    - quit (SubagentSessionsTests) and recordInterruptedRun (RedriveInterruptedRunsProcessTests) both call closeClientSide, so every use is covered.
    - other new IntegrationTests files checked: no `try?`; no other unobserved Task with a dropped result (readLiveTrace reader is awaited; its limit timer Task only sleeps and its catch only sees the cancel of the sleep). Dropped `_ =` values are exit statuses, not errors; left as is.
    - changed file: IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/NestedRootSession.swift
    - builds: `swift build --build-tests --package-path IntegrationTests` complete, no warning; `swift build --build-tests` complete. IntegrationTests were not run (order).
    - next: /review
  timestamp: 2026-11-04T19:11:50.599092+00:00
depends_on:
- 01M6GM17VHZSWD4G2J27WTA3JT
- 01M6GK6AH3R589GF241923KNDP
- 01M6GH3GPC9H1JYKV6GVANTFD9
- 01M6GH3NTR334G36C0FMY9MBDF
- 01M6GH3TN6QK7ZCSXTNWD6MNVW
- 01M6GH43RRA3D4ACVCWNWSAMY7
- 01M6GH3ZHE52GHWAZ53AWNKJ0K
position_column: review
position_ordinal: '80'
title: 'Integration test: nested sub-agent run end to end over the ACP wire, and update the docs'
---
## What
Prove the whole path with the real `acp-agent` binary and the ACP client, not only with unit tests.

- Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift`. Follow the shape of the existing tests there (spawned `acp-agent`, the `FoundationModelsACPClient` side). Use the stub or echo model of `Sources/FoundationModelsACPAgent/Configuration/` so no real model is needed. The prompt makes the root start an agent, and that agent starts a nested agent.
- Update `ARCHITECTURE.md` and `README.md`: say that a sub-agent is an ACP child session, say where it is projected, and name the restrictions. `ARCHITECTURE.md` needs an update because a new component (`SubagentSessionTable`, `SubagentProjector`) joins the structure.
- Update the comments of `RunCallJoinTable` and `AgentsComposition` that say the agent run sends no wire update.

Note: the ACP client package (`FoundationModelsACPClient`) has no code for child sessions today (`ConnectionModel` and `SessionModel` route by session id from `session/list` and `session/new`). If the client drops or mishandles updates of an unknown child id, this test shows it. Do NOT change the client package from this task. Write the finding in the task comment; a card on that project must be discussed with the user first.

## Acceptance Criteria
- [ ] The test sees, in order: `subagent_update` (child), `subagent_update` (grandchild), child events under each id, `idle` for each.
- [ ] `session/list` shows only the root session.
- [ ] `session/cancel` on the child id ends only the child.
- [ ] `session/resume` with `replayFrom: start` replays the chain parent first.
- [x] `ARCHITECTURE.md` and `README.md` describe the new components.

## Tests
- [x] The new `SubagentSessionsTests` in the IntegrationTests package.
- [ ] Run the integration test command of that package (`swift test --package-path IntegrationTests --filter SubagentSessionsTests`). All pass.
- [ ] Run `swift test` at the root. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-04 12:53)

> Scope: `review sha 4906c02~1..4906c02` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift:121` `reuse/reuse` — The teardown of a NestedRootSession is written out inline here. The prompt cancel and the connection close repeat what `quit` does in SubagentSessionsTests, so the teardown sequence now lives in two places. Add a teardown method to NestedRootSession, for example `closeClientSide()`, that cancels the prompt and closes the connection. Call it from `quit` and from `recordInterruptedRun`. The kill step stays where it is.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:91` `reuse/reuse` — The gate path is built by hand with `makeResolvedDirectory(...).appendingPathComponent("never")`. The same construction is written inline in RedriveInterruptedRunsProcessTests.swift:95, so the gate convention is repeated in two places rather than kept in one helper. Add one helper, for example `NestedAgentFixture.gateFile(label:)`, that returns the never-opening gate URL. Call it from both suites.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:142` `reuse/reuse` — `leafIsWorking` looks up the child of the root and then the leaf of that child with a guard. The same pair of `firstChild(of:)` lookups is written again in the settle predicate of `runFinishedChain` (line 176), and again at lines 291-292 in `runWorkingChain`. The chain lookup is repeated instead of kept in one helper. Add one helper on `[WireTraceEvent]`, for example `chain(of root:) -> (child: SessionId, leaf: SessionId)?`, built on `firstChild(of:)`. Use it in `leafIsWorking`, the settle predicate of `runFinishedChain`, and `runWorkingChain`.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:260` `reuse/reuse` — `WorkingChain` has the same fields as `FinishedChain` at line 149 (session, trace, child, leaf). Two result types with the same shape can drift apart and need the same change in two places. Use one chain result struct for both the finished and the working chain. Both helpers return it.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:307` `completeness/public-output-contract` — The refusal test for a child's session/prompt accepts any error. The test does not check the error code or id that the refusal sends. A prompt that fails for another reason, such as a transport error or a crash, would also pass. The refusal contract is therefore not proven. The same weakness applies to the session/close check on line 308. Assert the specific refusal error (its JSON-RPC code or message) for both `prompt` and `closeSession` on the child id. Keep the existing assertion that the root session still works.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:307` `test-integrity/no-test-cheating` — The refusal check accepts any error, not the refusal the test name describes. A transport close, a crash or an unrelated failure also passes, so the test does not prove the child refuses `session/prompt`. Assert the specific error that the agent returns for a refused method, for example the JSON-RPC method-not-permitted code or a message match, so an unrelated failure fails the test.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:308` `test-integrity/no-test-cheating` — The refused-close check accepts any error, so a close that fails for an unrelated reason passes as a refusal. Assert the specific refusal error code or message for `session/close` on a child, as in the prompt check.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift:396` `reuse/reuse` — The private static `resume` reimplements the cold-resume driver that already exists as `resume(recording:)` in RedriveInterruptedRunsProcessTests. Both spawn a SpawnedACPAgent, connect, initialize, subscribe, call readResumeTrace, then close the connection and stdin. The only real differences are the script and the `replayFrom` field. Two copies will drift apart, for example when the timeout or the close order changes in one of them. Extract one shared resume helper into NestedAgentFixture or a support file. Parameterize it by the script, the workspace and config home, the resume request (with or without `replayFrom`), and the settle predicate. Both suites then call it.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/LiveTraceReading.swift:100` `reuse/reuse` — `isCancelledIdle(of:)` is a near-match of `isIdle(of:)` at line 89. It repeats the same stream check and `stateUpdate` extraction, and differs only by the stop reason. The right move was to parameterize `isIdle` by an optional stop reason instead of writing a parallel copy. Replace both with one function, for example `isIdle(of:stopReason:)`, where the stop reason defaults to nil and the check compares it when given. Keep the existing call sites working through a thin wrapper, or update them.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/NestedAgentFixture.swift:49` `reuse/reuse` — `isCompletedCall` rewrites the `.update(stream, .toolCallUpdate(call))` pattern match by hand. The same extension already has the `stream` and `sessionUpdate` accessors, and `isToolCall(on:)` in LiveTraceReading.swift uses them. Each new copy of the pattern is another place to change if the update shape changes. Write it as `stream == session, case .toolCallUpdate(let call)? = sessionUpdate, call.toolCallId == id, call.status == .value(.completed)`, using the existing accessors.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/NestedRootSession.swift:42` `reuse/reuse` — The spawn, connect and initialize sequence is written out again here. The same sequence exists in the `resume` helpers of both test suites, so the connection setup now lives in three places. Extract a helper that spawns the agent, connects the model and initializes it, and returns those values. `NestedRootSession.start` and both `resume` helpers call it. `start` then adds only the new session.

## Review Findings (2026-11-04 13:05)

> Scope: `review sha 4906c02~1..6510361` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 8 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 2 file(s) not reviewed — no validator matches this file:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/NestedRootSession.swift:48` `test-integrity/no-test-cheating` — The root prompt runs in an unobserved `Task`, and nothing awaits its result, so an error thrown by `connection.prompt` is discarded. A prompt that fails mid-run can leave the trace assertions passing while the root's failure goes unreported. This is a swallowed failure. Await the prompt's result in the test's end path, for example by calling `try await session.prompt.value` before `quit`, or by having `closeClientSide()` or `quit` check that the prompt ended without error or with the expected cancellation. Report any error that is not the expected cancel of the kill or close.
