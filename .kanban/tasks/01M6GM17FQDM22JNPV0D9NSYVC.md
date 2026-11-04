---
comments:
- actor: wballard
  id: 01m6gpcxzgs9zcn4j0y934v6q8
  text: 'UPDATE (2026-11-03): the re-vendor to schema-v2.0.0-alpha.13 is DONE and pushed (commit 4e0667c). The stable `StateUpdate` now has `background: [BackgroundWork]?`, but the stable `BackgroundWork` has only `.terminal` and `.toolCall` (plus `.unknown`). The `subagent` entry is NOT in the stable schema. So the `terminal` and `tool_call` entries of this task can be built now (after the adoption task 01M6GPCJ3CMS7YE71DQ3J33QC8). The `subagent` entry needs the wire types card (01M6GJ664BHY454C5NFPFCSP79), which must also give the unstable subagent entry for the background list. Split the work accordingly, or wait for the wire card for the sub-agent part.'
  timestamp: 2026-11-03T12:33:29.584172+00:00
- actor: wballard
  id: 01m6h6kmkzk3j7ahbexszq1887
  text: 'SPEC REVIEW (independent, 2026-11-03): no state_update has a background list today (SessionStateLedger.currentSnapshot returns running, requires_action, or idle with only the noWork meta). A running sub-agent is never listed and no subagent_update is sent before a listing snapshot. This task fixes it: every state_update carries background once the agent reports it; a listed item is announced before and finalized before removal; the resume sync sends the pre-response item updates before the current state_update.'
  timestamp: 2026-11-03T17:16:46.591620+00:00
- actor: claude-code
  id: 01m6j9vs5c2x9vrgprtape3zmg
  text: |-
    step: implement
    outcome: changed
    evidence: 14 files. New: Agent/BackgroundBook.swift, Agent/BackgroundWatch.swift, Tests/BackgroundListTests.swift. Changed: Agent/PromptState.swift, SessionProjector.swift, TerminalStream.swift, SessionBuild.swift, SubagentAnnouncement.swift, SessionResume.swift, SessionHistory.swift, SessionSetup.swift, Tests/Support/ProjectionTestSupport.swift, README.md. Filtered run (BackgroundListTests and the suites of the touched files): 280 tests passed, 0 issues.
    task: ^d9nsyvc

    How it works. The state ledger holds a BackgroundBook. Every state_update carries the list: [] when nothing runs apart. A list change sends the state again to the snapshot sink, so the retained history state stays. A source reports a change only after its wire update went out. Tool calls: BackgroundWatch sits under the final-status hold in the projector. A run is detached when its SDK toolStatus returns while the run is open and has progress. The call is listed after its tool_call_update. It leaves after the final status update reached the sink, so a held agents final status keeps the call listed. Terminals: TerminalStream reports the announce and the exit. A terminal replaces its call in the list. Sub-agents: a child ledger tells its parent when it is active (version numbers drop old reports). The parent lists the child after the subagent_update went out, and drops it when the child is idle or retired. Resume: syncCurrentState sends the current update of each listed item from the retained history before the snapshot, unless a replay ran.

    Discoveries. (1) The close record of a plane run comes after its terminal event, so it is no detach signal. The SDK toolStatus before the settlement is the signal. This is the real Router order, and the RealStream tests prove it. (2) A gated child ledger blocks in deliver until its subagent_update went out, so a child can not be active before its announcement. (3) After a resume the entry has a new ledger, so the list is empty at a resume today. The item sync is ready for the hot resume task.

    Open: the acceptance item "session/cancel of the parent leaves the listed work running" is NOT done here. The card text gives it to the cancel task ^wd6mnvw, which depends on this card. It needs the change from cancelAll() to cancelForeground() in cancelRunningPrompt, with the README and the tests of the cancel behavior. The box stays unchecked.
  timestamp: 2026-11-04T03:32:53.548774+00:00
- actor: claude-code
  id: 01m6jabktkaw6s71jfnq11r9et
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD. 0 findings, 0 confirmed, 2 refuted, 21 attempted, 0 failed. No file:line items.
    - unchecked item "session/cancel of the parent leaves the listed work running": the card text gives it to card ^wd6mnvw. That card has the criterion "session/cancel on the parent does not cancel a background child" and a test for it. It depends on this card. The card text releases this item. It is not a finding.
    - next: card moved to done.
  timestamp: 2026-11-04T03:41:32.371076+00:00
depends_on:
- 01M6GM0N9BFK37GGBWPAG9VE1X
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: done
position_ordinal: ffffa280
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
- [x] Every `state_update` of a session that reports background work carries `background`; `[]` when nothing runs.
- [x] A detached tool call appears in the list after its `tool_call` update and leaves after its final status.
- [x] A running sub-agent appears as `{type: subagent, sessionId}` after its `subagent_update`; an idle child without background work does not.
- [x] A resume sends a current update for each listed item that the replay did not cover, before the snapshot.
- [ ] `session/cancel` of the parent leaves the listed work running (cancel task).

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/BackgroundListTests.swift`: announce before list, finalize before removal, subagent rules, resume ordering, repeated snapshot is not a transition.
- [x] Run `swift test --filter BackgroundListTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents