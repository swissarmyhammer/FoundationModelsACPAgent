---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7cysj1t33jq8mqf3t3n8a2a
  text: |-
    Research and findings:
    - New suite Tests/FoundationModelsACPAgentTests/ScheduledAgentEndToEndTests.swift drives the agent over the wire with the scripted model. The schedule is a one-time ISO date 3 s ahead (`every N minutes` has a 1-minute floor; the scheduler clock is internal to FoundationModelsAgents, so no fake clock from outside). Each wait has a 20 s bound plus the 1-minute suite limit.
    - `session/prompt` responds before the work ends (no turns), so the fixture waits for the root's `idle` with `_meta.noWork` before it acts. An earlier draft that cancelled or shut down right after the prompt response hit the prompt in the middle (cancelled before the tool call ran). When the tests ran in parallel, the shutdown variant then hung past the time limit. Not investigated further.
    - BUG (this repo, fixed TDD): the result mail of a firing never reached the client. The scheduler mails through AgentRunHost.callerMail -> directory.send. The caller's `mailDelivered` gave the projector a receive step with no send step, so no `session_message` was sent. Fix: SubagentMessageProjector.mailed(_:from:to:text:) (the host mail route), called from AgentRunLinks.callerMail with the receipt's MailID. The same path also carries the result mail of restored runs.
    - PEER ISSUE (FoundationModelsAgents, not edited): AgentRunner.cancelRuns(caller:) runs on every user session/close. It calls AgentScheduler.endTasks(owner:), which ends the tasks and saves [] (ScheduleFileStore deletes schedules.json), so a cold resume after a close restores nothing. Its doc says this is intended ("the close of the session ends it and removes its saved copy"). That conflicts with the card's requirement (and with the cancel-is-kill rule that spares scheduled agents). The test is marked withKnownIssue. Shutdown + cold resume works and passes.
  timestamp: 2026-11-14T11:58:56.058533+00:00
- actor: claude-code
  id: 01m7cz20k205apsmh3xr9gzdj4
  text: |-
    ### implement — changed
    - evidence: 4 files. Tests/FoundationModelsACPAgentTests/ScheduledAgentEndToEndTests.swift (new, 9 tests), Sources/FoundationModelsACPAgent/Agent/SubagentMessageProjector.swift (host mail route `mailed(_:from:to:text:)`), Sources/FoundationModelsACPAgent/Agent/AgentRunLinks.swift (callerMail hands the receipt to the projector), README.md (four message routes). Full `swift test`: 2080 tests in 224 suites passed, 2 known issues (HarnessSmokeTests was already there; aScheduleSurvivesACloseAndAColdResumeAndFires is the FoundationModelsAgents close issue), no warnings in project files.
    - Under load the scheduled time passed before the tool read it, so the tool refused the call. The call now reads its arguments from a file that the test writes when the pass reaches the call (`.writeFile` + `.toolCallFromFile`). The lead time is 5 s.
    - next: /review. The peer issue (close ends schedules) waits for a decision and a FoundationModelsAgents change.
  timestamp: 2026-11-14T12:03:33.090598+00:00
position_column: doing
position_ordinal: '8280'
title: End-to-end test of a scheduled agent through the ACP surface
---
Open item of ^kw4mt32 (carried over from ^2pa0kzs): "A real end-to-end test of a scheduled agent".

Prove through the ACP surface (a client drives the agent over the wire with the scripted model; no direct calls into FoundationModelsAgents internals):

- [x] A session schedules an agent with the `agents` tool (`schedule agent`).
- [x] The scheduled agent fires at its time.
- [x] The result of the firing reaches the caller session as a message (`session_message`). Bug fixed here: the host mail route of the projector.
- [x] While the firing runs, the session is held out of the no-work state (the `childSession` lease, `scheduledAgentWorkSite`, e61c18c): no `idle` with `_meta.noWork` while it runs. Proved for a fresh schedule and for a schedule restored by a cold resume.
- [ ] The schedule survives a `session/close` + cold resume: it is restored and fires. Test written and marked `withKnownIssue`. FoundationModelsAgents `AgentRunner.cancelRuns(caller:)` ends the schedules on close and deletes schedules.json. Waits on a decision and a peer change. Shutdown + cold resume passes.
- [x] `session/cancel` keeps the schedule (a73daeb), and it still fires.

Rules: reuse ScriptedPromptFixture / ScriptedPlaybook fixtures; short schedule; every wait time-limited; TDD for any bug found here; a bug in a peer package gets `withKnownIssue` and a report, no edit of .build/checkouts.

#bench