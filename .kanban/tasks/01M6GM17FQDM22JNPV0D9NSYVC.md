---
comments:
- actor: wballard
  id: 01m6gpcxzgs9zcn4j0y934v6q8
  text: 'UPDATE (2026-11-03): the re-vendor to schema-v2.0.0-alpha.13 is DONE and pushed (commit 4e0667c). The stable `StateUpdate` now has `background: [BackgroundWork]?`, but the stable `BackgroundWork` has only `.terminal` and `.toolCall` (plus `.unknown`). The `subagent` entry is NOT in the stable schema. So the `terminal` and `tool_call` entries of this task can be built now (after the adoption task 01M6GPCJ3CMS7YE71DQ3J33QC8). The `subagent` entry needs the wire types card (01M6GJ664BHY454C5NFPFCSP79), which must also give the unstable subagent entry for the background list. Split the work accordingly, or wait for the wire card for the sub-agent part.'
  timestamp: 2026-11-03T12:33:29.584172+00:00
depends_on:
- 01M6GM0N9BFK37GGBWPAG9VE1X
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: todo
position_ordinal: 8d80
title: State snapshots carry the background list (tool calls, terminals, running sub-agents) with announce-before-list ordering
---
## What
ACP v2 "Background Work" RFD: every `state_update` snapshot (`running`, `requires_action`, `idle`) may carry a `background` array of work that detached from the foreground. Entry types: `terminal` (`terminalId`), `tool_call` (`toolCallId`), `subagent` (`sessionId` of a child associated through `subagent_update`). An agent that reports background work MUST include `background` on EVERY `state_update` of the session. A concrete list replaces the previous one; `[]` means nothing runs in the background; omitted or `null` means "not reporting" (which is NOT "nothing runs").

Rules to keep:
- Announce first: a `terminal_update`, `tool_call` / `tool_call_update` or `subagent_update` MUST come before the snapshot that lists the item.
- Finalize before removal: the final status (or `exitStatus`) MUST come before the snapshot that drops the item.
- Resend `state_update` when the list changes; a repeated snapshot is not a transition.
- A subagent is listed while its state is not `idle`, or while its own `background` list is non-empty or unreported. An idle child with no background work is not listed.
- A tool call whose only live work is a listed terminal is not listed separately.
- The foreground work that the turn waits on is NOT listed.
- If follow-up foreground work starts when an item is removed, report `running` in the same snapshot or earlier.
- On resume: the snapshot carries `background` like any other; before it, send a current update for each listed item that the replay did not deliver at its current state. With no replay, send all of them.

Why it matters here: a `start agent` call that outlasted its settle period is background work; a running sub-agent is a listed `subagent`; after a hot resume a client learns about running children from this list; a re-driven original call is a listed `tool_call`.

Where: `SessionStateLedger` (`Sources/FoundationModelsACPAgent/Agent/PromptState.swift`) builds the snapshots. It has no `background` today (I found none in the projector, the lifecycle or the resume code). The sources of background work are the run plane of the session (settled runs), the shell terminals (`RunCallJoinTable`, `TerminalStream`), and the agent runs (`AgentRunner` runs, `AgentRun.state`).

Needs (not in this package): the `background` field on the Swift `StateUpdate` types. It is in the schema from alpha.12; the vendored schema is alpha.8 (re-vendor card on the FoundationModelsACP board, `01M6GJ8GX6C0YRHJW0W2ADAVTE`). Do not start before that card is done. Task `1vmbam7` (announce) is needed for the `subagent` entries.

## Acceptance Criteria
- [ ] Every `state_update` of a session that reports background work carries `background`; `[]` when nothing runs.
- [ ] A detached tool call appears in the list after its `tool_call` update and leaves after its final status.
- [ ] A running sub-agent appears as `{type: subagent, sessionId}` after its `subagent_update`; an idle child without background work does not.
- [ ] A resume sends a current update for each listed item that the replay did not cover, before the snapshot.
- [ ] `session/cancel` of the parent leaves the listed work running (cancel task).

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/BackgroundListTests.swift`: announce before list, finalize before removal, subagent rules, resume ordering, repeated snapshot is not a transition.
- [ ] Run `swift test --filter BackgroundListTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents