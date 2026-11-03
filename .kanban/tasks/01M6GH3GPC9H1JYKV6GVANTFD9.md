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
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: todo
position_ordinal: '8380'
title: Project a child session to the wire with the same projector as the root, under the child session id
---
## What
A child session is an ordinary session (user decision, 2026-11-03). Its events must be projected by the SAME `SessionProjector` and `ACPEventTranslator` code as the root, each with its own ACP session id. Do not write a `SubagentProjector`.

The child entry from the first task already has its own projector (attached to the child Router session), ledger, and history sink. This task makes the projected updates correct and keeps the two sessions apart:
- The projector of the child sends `session/update` with the CHILD `sessionId` (messages, thoughts, tool calls, tool output, `state_update`: running, requires_action, idle with `stopReason`/`error`). Check `Sources/FoundationModelsACPAgent/Agent/SessionProjector.swift` and `ACPEventTranslator.swift`: the translator has one `sessionId`; there is one translator for each projector, so one projector for each session keeps them apart.
- `RunCallJoinTable` (`Agent/RunCallJoinTable.swift`) is a table of the root session surface. Decide if a child shares it or has its own; the tool call ids of a child and of the root must never collide, and a child shell run must open its `Terminal` under the child id. Change `AgentsComposition.makeRunEventObserver` so it no longer writes "no join" for the child runs, and update the comments of `RunCallJoinTable` that say "The agent run sends no wire update of its tool runs".
- The announcement (`subagent_update`) goes out before the first update of the child (the announce task); this task depends on it.
- A child goes `idle` when its answer ends. It does not end. It keeps its id for the next assignment.

## Acceptance Criteria
- [ ] A stub run with two tool calls gives `tool_call` and `tool_call_update` messages with the child id, in order, after the `subagent_update`.
- [ ] The root stream has no event of the child, only its own `agents` tool call.
- [ ] `state_update` for a child: running at start, idle with `stopReason` at the end; a failure carries `error`.
- [ ] Tool call ids of a child and of the root never collide; a child shell run opens a `Terminal` under the child id.
- [ ] No class named for sub-agents duplicates the root projection code.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift`: ordering, id separation, state transitions, nested child.
- [ ] Update the `RunCallJoinTable` tests for the new entry.
- [ ] Run `swift test --filter "ChildSessionProjectionTests|RunCallJoinTable"`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents