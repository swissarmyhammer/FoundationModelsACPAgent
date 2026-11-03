---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gmveznxs1bcttr6jz4q3wd
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    1. Add the child terminal rule as its own card: the shell capability and the shell identity belong to the ROOT session surface (AgentsComposition doc; one shellSessionIdentity bind). Opening a Terminal under the child id needs a per-run owner id (AgentRun.id) in the join table and the identity. Do not do this here; keep the 'no collision of tool call ids' rule only.
    2. 'A child goes idle ... keeps its id for the next assignment' is wrong for the Agents package today: a finished AgentRun closes its session. Report idle and keep the association.
    3. Gate the sink until the announce is queued (see the shared build comment).
  timestamp: 2026-11-03T12:06:28.597632+00:00
- actor: wballard
  id: 01m6gp1xgrw2q6mgrsw0j52cz8
  text: |-
    DECISION (user, 2026-11-03): the agent is a session AND a tool, so it has the behaviors of both. ACP does not link the tool call to the child session, so we add a link in `_meta`, using the SAH extension pattern of the wire package (FoundationModelsACP `SAH/SAHMeta.swift`: payload types under `_meta.sah`). Card for the payload type: see the FoundationModelsACP board, "SAH meta payload that links an agent tool call and its child session".
    THE LINK:
    - On the `subagent_update` of a child: `_meta.sah.agentRun = { toolCallId }`, the id of the `agents` tool call that started the child (the SDK tool call id; the Router record has it as `agentSpawn.parentToolCallId`).
    - On the `tool_call` / `tool_call_update` of that `agents` call: `_meta.sah.agentRun = { sessionId }`, the child session id.
    THE REMOVAL RULE: a finished child is removed. ACP has no removal message. The agent sends none. The CLIENT removes a child from the tree when its linked tool call reaches a final status (completed, failed or cancelled). The agent must therefore send the final `tool_call_update` AFTER the last update of the child and after its final `state_update` (idle), so the client never drops a child that still has traffic coming.
    AGENT: put the link on both messages; keep the order above; the link is also sent in the replay and in the post-response snapshots of a restored child. A child that has no known tool call (a host-started run) carries no link, and stays until its parent closes.
    CLIENT: read the link; `SessionModel` gets `startedByToolCallId` and a tool call entry gets `childSession`; remove the child (set `isClosed`) when the linked tool call is final; keep the child if the link is missing.
    VIEWS: the `agents` tool row in the parent thread is a link that jumps to the child session while it exists; after removal the row stays as history and shows the result.
    Acceptance criteria to add: the link is on both messages; the child is removed on the final tool call status; no child traffic after its removal; a child without a link is not removed; replay and snapshots carry the link; cancel through `tool_call/cancel` and through `session/cancel` on the child id reach the same run.
  timestamp: 2026-11-03T12:27:28.664846+00:00
- actor: wballard
  id: 01m6grj2gdhq0sq75bgxe4a37c
  text: |-
    WIRE NOTE (2026-11-03, from ACP commits c1b6d20, ded0830 and the _meta key-patch commit): the wire types exist now. SessionUpdate has subagentUpdate, sessionMessage and sessionMessageChunk. SubagentUpdate has patch fields (title, description, capabilities, state, cwd, additionalDirectories, meta). SAH.AgentRun (stored at _meta.sah.agentRun) links the tool call and its child: toolCallId on the subagent_update, sessionId on the tool_call and tool_call_update. BackgroundWork has a sub-agent case.
    RULE FOR THIS TASK: _meta on an upsert now patches by TOP-LEVEL key. A key that is sent replaces that key whole. So the agent must never send a partial `sah` object: if it sends `_meta.sah`, it must carry all the members that must stay (use SAH.AgentRun.inject on top of the existing _meta, keep the other `sah` members). The _meta of a chunk is scoped to the chunk and never changes the stored entry.
  timestamp: 2026-11-03T13:11:15.213217+00:00
- actor: wballard
  id: 01m6h6kn1y6bqqmc12verg54at
  text: 'SPEC REVIEW (independent, 2026-11-03): nothing in the announcer orders the final tool_call_update of the agents call AFTER the final idle subagent_update of the child (rule: the final tool_call_update comes after the last update of the child and after its final state). Make this ordering explicit in this task, with a test, and route both through the one ordered queue.'
  timestamp: 2026-11-03T17:16:47.038796+00:00
- actor: claude-code
  id: 01m6he0aaj94sfzn8c23dq54c5
  text: |-
    Implementation done, left for review. Root swift test: 1445 tests in 155 suites pass (1 known issue in HarnessSmokeTests, old).

    What was built. One code path for all sessions. No "if child" branch, no SubagentProjector.
    - A. The announcer keeps the outputs of each run from its FIRST event (SubagentAnnouncer.observe(run, output:)). The announcer also takes the live Router session with RouterSessionDirectory.session(id:) at that first event. Before the first announcement, the agent calls registerNestedSession(session, parent:, events:). The child projector reads those outputs. Each child has its own translator, ledger, history sink and RunCallJoinTable. DEVIATION: the projector reads the kept outputs and does not subscribe to the Router session later. A later subscription loses the first events (the Router has no replay), and the announcement waits for the join entry. The observer still sends nothing itself, so each event goes to the wire once.
    - Gate. SessionAnnouncementGate now KEEPS each send while it is closed. Open sends the kept sends in order and then goes live. A send during the open goes after the kept sends. History still records at once. So the first events of a child are not lost.
    - B. The first delivery sends the subagent_update, then a tool_call_update on the agents call with _meta.sah.agentRun.sessionId (whole sah object, SAH.AgentRun.inject; the translator holds no other _meta for a tool call).
    - C. AgentCallHolds (shared by the join tables of one surface): the announcer holds the call of a run at its first event (token key). The join table sink (deferringFinalStatus) keeps a final status of a held call. At the end of the run the outlet does settle: the child projector sends its last updates and the final idle with the stop reason (SessionProjector.end(with:)), the child retires, and then the hold is released through the parent inbox (SessionProjector.releaseHold(of:)), so the final tool_call_update goes after each update of the child. This also holds for a run that goes to the background (the call returns early, the final status waits). Tested with SubagentWireTraceValidator: zero violations for a foreground run, a background run and a chain of three sessions. Mutation check: without the hold, the background test fails.
    - D. settleSubagent drains the child, then retireSession (teardown, detach, tree link removal).

    Not done / out of scope. Child shell terminals under the child id (the root surface owns the shell; RunCallJoinTable.recordAgentRunEvent still writes no join in the root table so the terminal stream does not wait). Relayed elicitation suppression and the child request gate (attribution task). Resume replay of child history. Background list. cancel by tool_call/cancel and by session/cancel on the child id.

    Notes for the next agent. (1) SubagentWireTraceValidator reads a toolCallId as one name for the whole trace, but ACP scopes it to the session. The scripted model gives scripted-call-N to each session, so root and child collide. The tests move the id of the agents call with two warmup runCode calls. (2) swift package update made RoutedSession require suspend(): I added it to CloseCountingRoutedSession (test support). (3) The child idle at the end comes twice: the workEnded idle (no stop reason) and then the final idle with the stop reason. (4) A run that goes to the background BEFORE its first event has no hold yet; the hold starts at the first event.
  timestamp: 2026-11-03T19:26:02.066156+00:00
- actor: claude-code
  id: 01m6hefax1yd49paa1hawbbegv
  text: 'REVIEW - findings. Engine: 0 findings (2 refuted), scope review sha 5c17720~1..5c17720. Manual read: 13 open items, written in the description. Main items: the hold is placed after watchEnd (a leak and a hang of the agents call), the hold starts at the first event (a background run before it), stop() does not release holds, the session lookup runs once, the output buffer and the gate list have no bound, and several tests pass without the hold. Next: the implementer fixes each item and runs the review again.'
  timestamp: 2026-11-03T19:34:14.177277+00:00
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: review
position_ordinal: '8380'
title: Project a child session to the wire with the same projector as the root, under the child session id
---
## What
A child session is an ordinary session (user decision, 2026-11-03). Its events must be projected by the SAME `SessionProjector` and `ACPEventTranslator` code as the root, each with its own ACP session id. Do not write a `SubagentProjector`.

The child entry from the first task already has its own projector, ledger, and history sink. This task makes the projected updates correct and keeps the two sessions apart:
- The projector of the child sends `session/update` with the CHILD `sessionId` (messages, thoughts, tool calls, tool output, `state_update`: running, requires_action, idle with `stopReason`/`error`). One projector for each session keeps the sessions apart.
- Each session has its own join table (`RunCallJoinTable`). The tool call ids of a child and of the root never collide. The child terminal rule is a separate card.
- The announcement (`subagent_update`) goes out before the first update of the child (the announce task).
- A child goes `idle` when its run ends. The association stays until the run ends and the final order is sent.

## Acceptance Criteria
- [x] A stub run with two tool calls gives `tool_call` and `tool_call_update` messages with the child id, in order, after the `subagent_update`.
- [x] The root stream has no event of the child, only its own `agents` tool call.
- [x] `state_update` for a child: running at start, idle with `stopReason` at the end; a failure carries `error`.
- [x] Tool call ids of a child and of the root never collide (each session has its own join table).
- [ ] A child shell run opens a `Terminal` under the child id. This is out of scope here. It needs its own card.
- [x] No class named for sub-agents duplicates the root projection code.
- [x] The `agents` call carries `_meta.sah.agentRun = { sessionId }` once the child is announced.
- [x] The final `tool_call_update` of the `agents` call comes after the last update and the final `idle` of the child (tested with `SubagentWireTraceValidator`).
- [x] The child entry is retired when its run ends, after the final order is sent.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift`: ordering, id separation, state transitions, link, final order, background run, chain of three sessions.
- [x] `AgentCallHoldsTests`, `SessionAnnouncementGateTests` and new announcer tests for the join table, the gate and the settle step.
- [x] Root `swift test`: 1445 tests in 155 suites pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

Status: in review.

## Review Findings (2026-11-03 14:10)

> Scope: `review sha 5c17720~1..5c17720`. The engine gave 0 findings (2 refuted). The findings below come from the manual read that the caller asked for.

- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncer.swift:566` `ordering/hold-race` — `observe(runID:watchEnd:makeReport:)` calls `watchEnd()` before `holds.hold(token)` (line 586). The watch task can see a finished run, prune it, and release the hold (a no-op) before the hold is placed. The hold then stays forever. The final `tool_call_update` of the `agents` call is then kept for ever and the call never ends on the wire. Place the hold before `watchEnd()`. Add a test with a run that has ended at its first event.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncer.swift:586` `ordering/background-before-first-event` — the hold starts at the first event of the run. A run that goes to the background before its first event has no hold. Its call returns early and the final status goes out before the child traffic. The client then removes a child that still has traffic. This breaks the rule of the SPEC REVIEW comment. Hold the call when the run starts, not at its first event. Add a test for it.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncer.swift:693` `leak/hold-never-released` — `stop()` does not release the holds. A run that is live at the stop keeps its hold, and the kept final status is lost. Release every hold at the stop, or send the kept statuses. Add a test.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncer.swift:545` `correctness/session-lookup-once` — `hasLookedUpSession` is set at the first event and the lookup is never tried again. When the directory has no session at that moment, the child is announced with no session of its own and loses all its content. Try the lookup again at the next event until it succeeds, or until the announcement. Add a test where the session appears after the first event.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncer.swift:250` `performance/unbounded-buffer` — `outputs` is an unbounded `AsyncStream`. It keeps every output of a run from its first event. No reader drains it when the session is unknown, when `registerChild` fails, or while the announcement waits for the link or for the parent. The memory grows with the run until it ends. Give the buffer a bound and a rule for the overflow, or drop the outputs when no reader exists. Add a test.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SessionAnnouncementGate.swift:67` `performance/unbounded-pending` — `submit` appends every send to `pending` while the gate is closed or flushes. The announcement can wait without a limit (blocked run, parent that waits). The list of kept sends grows without a limit, and a gate that never opens keeps them until the run ends. Give the list a bound, or tell the gate when the run ends so it drops the sends. Add a test for a gate that never opens.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SessionAnnouncementGate.swift:67` `ordering/send-returns-before-post` — during the flush `submit` returns at once, before the send ran. A caller that waits for its send (for example the slash command `sent` continuation of `SessionProjector`) resumes before the update is on the wire. Make `submit` wait for the send of its own update, or write in the contract that it does not.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SubagentAnnouncement.swift:187` `ordering/settle-without-announcement` — `settleSubagent` can run for a run that was never announced (final report pruned before the link). The hold is released and the final status goes out with no `subagent_update` before it, and the sends kept in a closed gate are lost. Write the rule for this case and add a test.
- [ ] `Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift:353` `tests/passes-without-code` — `theFinalStatusOfTheAgentsCallComesAfterTheLastUpdateOfTheChild` and `theWireOfARunFollowsTheRulesForSubagentSessions` run a foreground call. The call returns after the child ends, so the order holds also when `AgentCallHolds` is removed. Only the background test needs the hold. Add a test where the final status of the call arrives before the end of the child in the foreground case (a fake outlet and a held join).
- [ ] `Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift:452` `tests/vacuous` — `theChildIsRetiredWhenItsRunEnds` checks `sessions[child] == nil` and an empty tree. These also hold when the child never registered. Check first that the entry existed during the run.
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentAnnouncerTests.swift:1` `tests/missing` — no test covers `observe(_:output:)`: the order of the kept outputs, the single lookup of the session, the end of the outputs at the prune and at `stop()`, and the settle of a run whose announcement is held. Add them.
- [ ] `Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift:304` `spec/double-idle` — the child sends two `idle` updates at the end: the first from `workEnded` has no stop reason, the second from `SessionProjector.end(with:)` has one. Add a test that shows the client model and the validator accept the pair (the second one is the end of the turn), and write the rule in the source comment.
- [ ] `Sources/FoundationModelsACPAgent/Agent/AgentCallHolds.swift:1` `clarity/ste-sentence-length` — doc comments have sentences with more than 20 words. Examples: `AgentCallHolds` (36 and 31 words), `SessionBuild` (27 and 29), `SessionAnnouncementGate.takeNextPending` (26), `SubagentAnnouncer.observe` (32 and 30), `SubagentAnnouncer.settle` (28), `AgentsComposition.makeRunEventObserver` (31), `RunCallJoinTable` (25 and 24), `SubagentAnnouncement` (24). Split each sentence in all files of the commit.
