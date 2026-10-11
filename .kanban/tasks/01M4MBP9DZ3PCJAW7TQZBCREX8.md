---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ncq4nzbq1gbp8szqn3s6f6
  text: |-
    FoundationModelsAgents pushed the observer to main: commit c658f044809ba04505d077690e990575146cec5d (their task ^tcm4mmh).

    - API (additive): `AgentEnvironment.RunEventObserver = @Sendable (AgentRun, SessionEvent) -> Void`; `AgentEnvironment.make(..., runEventObserver: RunEventObserver? = nil)` (last parameter).
    - Each run calls it, child runs too. The open record is `.toolInvocation(record, toolCallID:)` with `record.closedAt == nil`; `record.correlationID` is the completion token of the tool run.
    - It is called synchronously in `AgentRun.follow`, before the run uses the event. It must return quickly. Two runs can call it at the same time.
    - No strict order against the first shell output. This is sufficient: `TerminalStream` holds a run that has no entry and releases it when the entry comes.

    Start this task after ^39h13a1, because both move a pin in Package.resolved.
  timestamp: 2026-10-11T11:49:06.879756+00:00
- actor: claude-code
  id: 01m4ng5bcf4mkfm1nssv6p34as
  text: |-
    Picked up. Research:
    - Pin moved in Package.resolved and IntegrationTests/Package.resolved: FoundationModelsAgents 016945e -> c658f04 (resolve with a new empty scratch path). The diff against the backups shows only that revision line; originHash did not change.
    - The surface (ToolCatalog.sessionSurface) is made per session: session/new and session/resume each compose one. AgentsComposition.compose runs inside it, so the agent environment is per session, not shared. The shell output stream is also a surface field.
    - Design: the surface owns the RunCallJoinTable. sessionSurface makes the table, gives it to AgentsComposition.compose (which passes runEventObserver to AgentEnvironment.make) and keeps it as SessionSurface.runCallJoins. ActiveSession reads entry.surface.runCallJoins, so one object owns the table and no token -> session lookup is necessary.
    - AgentRun has no public init. The wiring test gets a real AgentRun from surface.agents.runner.start (as AgentsToolTests does).
  timestamp: 2026-10-11T12:49:18.223631+00:00
- actor: claude-code
  id: 01m4nh6ty5qyxmjjx3v4akryta
  text: |-
    Implementation landed (TDD, two cycles):
    - Cycle 1 RED (stub `recordAgentRunEvent`): `aRootShellRunThatStartsAfterAnAgentRunEndedKeepsItsSdkId` failed on the old table (announce on the completion token 01JOIN...0001, not call-shell-1): this is the old race. `anAgentShellRunGetsItsEntryFromItsOwnOpenRecord` failed by the 1-minute time limit (no entry). GREEN after `RunCallJoinTable.recordAgentRunEvent(_:)` and the removal of `runDidEnd(tool:)`, `agentsToolName` and the two EventProjection callers: 3/3 pass.
    - Cycle 2: the surface owns the table (`SessionSurface.runCallJoins`, made in `ToolCatalog.sessionSurface`); `ActiveSession.runCallJoins` is gone, PromptExecution and the terminal stream read `entry.surface.runCallJoins`. RED: `AgentsToolTests.theOpenRecordOfAToolRunOfAnAgentRunWritesItsEntryWhileTheRunIsInOperation` failed (`runEventObserver` nil). GREEN after `AgentsComposition.makeRunEventObserver(runCallJoins:)` was passed to `AgentEnvironment.make(runEventObserver:)`.
    - Note: when the observer test hangs (no entry), `recorder.updates {}` does not react to the time-limit cancel, so a RED run of that test hangs until a kill. That is the behavior of the existing test helper; it is not new.
    - The "no prompt open -> no join at once" rule stays: no projection writes an entry for a root run after its prompt ended (for example a root run whose open record a cancelled prompt never handled). Without the rule such a run waits until the shell output stream ends.
  timestamp: 2026-10-11T13:07:35.493842+00:00
- actor: claude-code
  id: 01m4nhjyekemn6vmxkwsv8jskq
  text: |-
    ### implement — changed
    - evidence: pin FoundationModelsAgents 016945e -> c658f04 in Package.resolved and IntegrationTests/Package.resolved (git-ignored; only that revision line changed, originHash the same). 8 files: Sources/FoundationModelsACPAgent/Agent/{RunCallJoinTable,EventProjection,SessionSetup,PromptExecution}.swift, Sources/FoundationModelsACPAgent/Tools/{AgentsComposition,ToolCatalog}.swift, Tests/FoundationModelsACPAgentTests/{ToolCallJoinProjectionTests,AgentsToolTests}.swift. Root `swift test --scratch-path .build/alt --force-resolved-versions`: 911 tests in 99 suites pass (1 known issue: the deliberate withKnownIssue in HarnessSmokeTests). IntegrationTests (`--no-parallel`, IntegrationTests/.build/alt): 35 tests in 13 suites pass. The only build warning is the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line of the build system, not of a source file.
    - note: TerminalStreamTests.swift and the ^39h13a1 card had changes from a parallel session during the runs; this task did not touch them.
    - next: /review
  timestamp: 2026-10-11T13:14:12.307622+00:00
position_column: doing
position_ordinal: '8180'
title: Give the host the tool records of an agent run, so the run-call join table gets exact entries
---
## Problem

Task ^9xk3xf4 makes `RunCallJoinTable` decide the wire id of each shell run from events only. A shell run of an agent run (the `agents` tool) uses the shell capability of the root session, so its output comes on the root `ShellOutputChunkStream`. But its `toolInvocation` records go to the event stream of the agent run, and FoundationModelsAgents reads that stream in a private loop (`AgentRun.follow` in `Run/AgentRun+Drive.swift`). `AgentEnvironment` and `AgentRunner` take no event observer. Thus this package cannot write an exact entry for such a run.

The fallback of ^9xk3xf4: the end of an agent run (the close record or the settlement of an `agents` run in the root projection) writes "no join" for each waiting run, and the end of the root prompt does the same.

## Known limit of the fallback

A root shell run that starts just after an agent run ended, and whose first chunk comes before the root projection handled its open record, also gets "no join" from the agent-end write. Then its terminal announce and its run updates go on the completion token, while the SDK `toolCall` and `toolStatus` events go on the SDK id: two tool calls for one run. The window is the lag of the root projection.

## What to change

- FoundationModelsAgents: give the host an observer of the session events of each agent run (for example, an `AgentEnvironment` parameter that receives each `SessionEvent` of a run, or only its `toolInvocation` records), or another public way to read the completion tokens of the tool runs of a run.
- FoundationModelsACPAgent: write "no join" into the `RunCallJoinTable` of the session for each open record of an agent run, before the shell body starts. Then remove the agent-end write (`RunCallJoinTable.runDidEnd(tool:)`).

## Acceptance

- [x] A shell run of an agent run gets its entry from its own open record, not from the end of the agent run.
- [x] A root shell run that starts after an agent run ended keeps its SDK id (a test with the root chunk before the root open record and after the agent-end event).
- [x] The agent-end write is gone.