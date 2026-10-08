---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4e0cajf7d38nqrsrm7adkjc
  text: |-
    Upstream status (2026-10-08):

    - Extras ^pfqfmjt is done and pushed. Feature commit ee4a798. The names agree with this task.
    - Router ^mq1js23 is done in the local commits 1d3d6f82, 299c7c2f and f9d6870b. They are NOT pushed yet. Do not start this task until they are on Router `origin/main`. Do not use a local path override.

    Facts from Router for this task:
    - `SessionEvent.runProgress(OperationEvent)` goes live for each `.progress` event.
    - The model never gets `OperationEvent.plan`.
    - The outbox merge key is `tool` + `correlationID` + `plan?.id`. A plan replaces only an earlier plan with the same `PlanSnapshot.id`. Text replaces only text.
    - In code mode, the events of a `tools.*` call have `tool == "runCode"` and the correlation token of the outer run. Thus, the text-progress arm must map the token of the outer run to its tool call id. Do not use `event.tool` to find the tool call.
    - Router writes each plan event to disk immediately. A restore gives the last plan for each plan id. The `session/load` replay can use this.
  timestamp: 2026-10-08T14:58:48.527927+00:00
- actor: claude-code
  id: 01m4e1cyz1a4bma5mt6zwa9bx1
  text: |-
    Research (2026-10-08):

    - Package.resolved: `swift package update FoundationModelsExtras FoundationModelsRouter` moved only these two pins. Extras 130eb40 -> 5c1c638 (holds ee4a798). Router 6bdf9ae -> f9d6870 (holds 1d3d6f82, 299c7c2f). No other pin changed. Package.resolved is in .gitignore, so git shows no diff.
    - The ACP wire case is `SessionUpdate.planUpdate(PlanUpdate)`, not `.plan`. `PlanUpdate(plan: .items(PlanItems(entries:planId:)))`.
    - The correlationID -> tool call id map of `projectToolCallReport` is the identity: `ToolCallId(rawValue: correlationID)`. The text progress arm uses the same map, and never reads `event.tool` to find the call.
    - `sawOutput` feeds `generatedNothing` (the `_no_output` stop) and the stall bound. A progress event tells about a run, not about the model generation. Thus the progress arm does not set `sawOutput`.
    - This agent has no `session/load`. Its replay is `session/resume` with `replayFrom: start`. The replay reads the retained history (`SessionMergeEngine`), which applies each sent `plan_update` and keeps the last plan of each plan id. A live plan goes through the history sink, so the history holds it.
    - The history file is written only at some points. Router writes each plan event to disk at once. So the resume also reads the recorded events of the session (`TranscriptEvent.merged(under: recordingDirectory)`, filtered on the session id, `operationEvents`, `plan`), takes the last plan of each plan id, and applies it to the history before the replay. The filter on the session id keeps plans of other sessions (forks) out.
  timestamp: 2026-10-08T15:16:37.985218+00:00
- actor: claude-code
  id: 01m4e2n35302p7v888tc9zyt3q
  text: |-
    Implementation landed (not committed).

    What changed:
    - `EventProjection.project(_:)` has a `.runProgress` arm (`projectProgress(of:)`). With a plan: one `.planUpdate(PlanUpdate(plan: .items(PlanItems(entries:planId:))))`. With no plan: a `tool_call_update` on `ToolCallId(rawValue: correlationID)` with the detail as content, status `in_progress`, name = tool, title = op (the same shape as the report and the settlement, because it can create the wire call). `event.tool` never selects the call.
    - `EventProjection.planUpdate(for:)` maps priority and status by raw value (`PlanEntryPriority(wireValue:)`, `PlanEntryStatus(wireValue:)`). The Extras raw values are the ACP wire values, so the map is total and keeps an unknown value.
    - The progress arm does not set `sawOutput`. A test proves that a prompt with a plan and zero output tokens still ends with `_no_output`.
    - `session/resume` (this agent has no `session/load`; resume with `replayFrom: start` is the replay): `resumedHistory(kept:directory:rootId:sessionId:)` reads `TranscriptEvent.merged(under: recordingDirectory)`, keeps only events of the session id, and merges each recorded plan into the history in post order. The merge engine keeps the last plan of each plan id. The filter on the session id keeps plans of forks and other sessions out.
    - The mandated Router update also brought `SessionEvent.runMessage` (Router 5713abe4, ^v270zf4). The switch warned "switch must be exhaustive". I added an explicit arm that keeps the earlier behavior: no wire message, a debug log line.
    - The mandated Extras update also brought Extras a91911d (breaking: `PooledEmbedding` has no `dimension`). `RecordingEmbeddingContainer.dimension` in the test support no longer compiled, so I removed it. No other code read it.
    - plan.md: §8.4 rows for `runProgress` and `runMessage`, a §7.4 rule for the recorded plans, and §13 Agent Plan rewritten (it said "we send nothing").

    Discovery: `swift format lint` with no config wants 2-space indentation. The repo has no `.swift-format` file and uses 4 spaces, so that lint does not apply here.
  timestamp: 2026-10-08T15:38:32.995468+00:00
- actor: claude-code
  id: 01m4e2n7g2tmnndb3gqc93bfbr
  text: |-
    ### implement — changed
    - evidence: `swift package update FoundationModelsExtras FoundationModelsRouter` moved only Extras 130eb40 -> 5c1c638 and Router 6bdf9ae -> f9d6870 (Package.resolved is git-ignored). RED: `swift test --filter RunProgressTests` 6 of 8 failed for the missing feature (2 guards passed). GREEN: 8 of 8 passed. Full `swift test`: 793 tests in 88 suites passed, 1 known issue (the deliberate withKnownIssue in HarnessSmokeTests), 0 warnings in package files. 7 files: Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift, Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Tests/FoundationModelsACPAgentTests/RunProgressTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/ResumeSessionFixture.swift, Tests/FoundationModelsACPAgentTestSupport/RecordingEmbedding.swift, plan.md. The nested IntegrationTests package was not run.
    - next: /review
  timestamp: 2026-10-08T15:38:37.442636+00:00
- actor: claude-code
  id: 01m4e312by7w6cq0v7g3zmjgr5
  text: |-
    ### test — green
    - evidence: swift test (root package) — 793 tests in 88 suites passed, 0 failed, 0 skipped, 1 known issue (the intended withKnownIssue in HarnessSmokeTests, orderedSubsequenceAssertionChecksOrderWithGaps). No compiler warning in this package's files. One build-system line: "warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" comes from the mlx-swift dependency bundle, not from a file in this package. Package.resolved and Package.swift are unchanged. No local path override.
    - next: none. No file was edited by this step. No commit was made.
  timestamp: 2026-10-08T15:45:05.406194+00:00
position_column: doing
position_ordinal: '80'
title: Send tool progress and tool plans to the client as session updates
---
## Goal

A tool sends updates during a call through `ToolContext.progress`. The agent must send each update to the client as an ACP `session/update`. The first use is an ACP agent plan (https://agentclientprotocol.com/protocol/v2/agent-plan).

## Upstream work (do this task after both are on `main`)

The tasks are on other boards, so this board cannot hold the dependency links. Check each upstream task before you start this task.

- **Extras** `01M4DV675C3BNZHBNFNPFQFMJT` (^pfqfmjt), on the FoundationModelsExtras board: "Send an agent plan through ToolContext.progress as a typed PlanSnapshot".
  - `public struct PlanSnapshot: Sendable, Codable, Equatable` in `Sources/FoundationModelsExtras/OperationEvents/PlanSnapshot.swift`. Fields: `id: String`, `entries: [PlanSnapshot.Entry]`.
  - `PlanSnapshot.Entry`: `content: String`, `priority: PlanSnapshot.Priority`, `status: PlanSnapshot.Status`.
  - `PlanSnapshot.Priority`: `.high`, `.medium`, `.low`.
  - `PlanSnapshot.Status`: `.pending`, `.inProgress` (raw value "in_progress"), `.completed`, `.cancelled`.
  - `OperationEvent.plan: PlanSnapshot?`. It is set only on `.progress` events.
  - `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil)`.
- **Router** `01M4DV630KDPW1KSTDRMQ1JS23` (^mq1js23), on the FoundationModelsRouter board: "Send .progress operation events live as SessionEvent.runProgress and keep the plan out of the model text".
  - `SessionEvent.runProgress(OperationEvent)`, sent live for each `.progress` event.
  - The plan is not in the model text. A plan event goes to disk immediately.

## Change

1. In `EventProjection.project(_:)` (`Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:309`), add a `.runProgress(let event)` arm.
   - If `event.plan` is set, send `.plan(PlanUpdate(plan: .items(PlanItems(entries:planId:))))`. Map each `PlanSnapshot.Entry` to `PlanEntry`. Map `PlanSnapshot.Priority` to `PlanEntryPriority`. Map `PlanSnapshot.Status` to `PlanEntryStatus`. `planId` is `PlanId(rawValue: plan.id)`.
   - If `event.plan` is nil, send `event.detail` as `tool_call_update` content of the tool call. Use the same `correlationID` → tool call id map that `projectToolCallReport` uses (`EventProjection.swift:707`).
2. A plan update does not set `sawOutput` in a way that changes the stop reason of the prompt. Check this.
3. `session/load`: replay the last plan of each `planId` from the transcript (`Agent/SessionHistory.swift`, `Agent/SessionResume.swift`).
4. The client must not get a plan from a session that did not make it.

## Tests

- A scripted tool calls `progress("3 of 7 done", plan:)`. The client gets one `plan` session update with the same entries, priorities, statuses and plan id.
- A tool calls `progress("812 lines")` with no plan. The client gets a `tool_call_update` with that text, on the correct tool call id.
- Two plan updates with the same id: the client gets two full lists. The second list replaces the first list.
- `session/load` of a session that sent a plan replays the last plan.

## Not in scope

The Kanban tool. The user decided to do it later.

#acp #tools