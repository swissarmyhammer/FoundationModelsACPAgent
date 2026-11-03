---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gjcrrm1e9ksgzy27j2extk
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:29.940665+00:00
- actor: wballard
  id: 01m6gmvfbgw00xy9aedvj8tktr
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    1. Today session/cancel calls cancelAll() on the session (PromptExecution.swift near line 887: it stops the queued mail, the model work and the background runs). 'Parent cancel stops only foreground work' is NOT current behavior. Name the change (cancelAll or the runner) and depend on the background list task.
    2. A child cancel is confirmed as idle with stopReason cancelled only if foreground work was active (prompt-lifecycle page). A child with no active work gets no new idle.
  timestamp: 2026-11-03T12:06:28.976618+00:00
- actor: wballard
  id: 01m6gsw65wfv85ph66ks4y3ehk
  text: |-
    WIRE CHANGE (ACP review fix b86bfc2, 2026-11-03, on top of c1b6d20 / ded0830 / 9f1bcd1 / 129fc9a): `ToolCallUpdate.capabilities` is now `PatchField<ToolCallCapabilities>` (was `ToolCallCapabilities?`), and `TerminalUpdate.capabilities` is now `PatchField<TerminalCapabilities>` (was `TerminalCapabilities?`). Rule: omitted leaves the value, `null` clears it, an object replaces the whole value. `AccumulatedTerminal` has `size: TerminalSize?` and `capabilities: PatchField<TerminalCapabilities>`, and replay keeps both. `ElicitationUrlMode.Scope` is now a typealias of `ElicitationFormMode.Scope`.
    EFFECT: this is break number 14 for the adoption task: fix every place that builds or reads these capabilities. It matters for the cancel task (a tool call advertises `cancel` in its capabilities; the agent must clear it with `null` when the call reaches a final status, and must not send capabilities again as a plain value on later updates).
  timestamp: 2026-11-03T13:34:15.228151+00:00
- actor: claude-code
  id: 01m6h7g3n2qzrxdagtcxdwd7f7
  text: 'UPSTREAM NOTE (ACP v2, PR 2743, text already in alpha.13): session/cancel does not stop work that is in the latest background list. The agent stops waiting for the pending requests of the CANCELLED work and SHOULD send $/cancel_request for them (the client answers a request cancelled by the agent with cancelled). For this task: (1) a parent session/cancel leaves the listed sub-agents running (they are in the background list) and cancels the foreground work, including the sub-agent that the turn waits for (not listed); (2) every pending elicitation (and any other agent-to-client request) of the cancelled foreground work gets $/cancel_request; none of a listed background child is cancelled. Add a test for both. Also watch (no card needed yet): draft RFDs 2756 (a failure session update replayed like messages), 2755 (error classification in the error data), 2485 (token usage semantics for sub-agents).'
  timestamp: 2026-11-03T17:32:19.490875+00:00
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
- 01M6GH353HTRBREVKKN3N2WZW8
- 01M6GM17FQDM22JNPV0D9NSYVC
position_column: todo
position_ordinal: '8580'
title: Cancel one child with session/cancel on the child id; parent cancel and close follow the RFD
---
## What
Make `session/cancel` work on a child id, and set the cancel rules of the RFD.

- `sessionCancel` in `Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift` (line near 898): when the id is a child id, cancel that run through `AgentRunner` (stored in `AgentsMount.runner`, `Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift`). Cancel also stops the descendants the run waits for. Background descendants may keep running.
- The cancel is confirmed as a child `state_update` `idle` with `stopReason: "cancelled"`.
- A `session/cancel` on the parent stops only foreground work. Listed background children keep running (v2 background-work RFD).
- A close of the parent cancels all descendant work. The session lifecycle already stops the runner before it closes the root session; keep that and add the cancelled `idle` for each child.
- Pending requests of a cancelled child are answered `cancelled`.

## Acceptance Criteria
- [ ] `session/cancel` on a child id ends only that run; the parent and the siblings continue.
- [ ] The client sees child `idle` with `stopReason: "cancelled"`.
- [ ] `session/cancel` on the parent does not cancel a background child.
- [ ] `session/close` on the parent cancels all children, nested too.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentCancelTests.swift`: child cancel, sibling unaffected, parent cancel with a background child, close of parent with a nested child.
- [ ] Run `swift test --filter SubagentCancelTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents