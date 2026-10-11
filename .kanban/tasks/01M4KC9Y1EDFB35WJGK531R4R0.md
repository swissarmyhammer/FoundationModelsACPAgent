---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4mfkph4eskq7c76re1ata76
  text: |-
    Research done.
    - `EventProjection.project` handles `.runSettled` (seal + `projectSettlement`), `.toolCall` (`projectToolCall`, always `status: in_progress`) and `.toolStatus` (`projectToolStatus`, status from Router: running -> in_progress, completed, failed). The SDK events carry the SDK id. The run events carry the completion token, and `RunCallJoinTable.toolCallId(for:)` gives the wire id (SDK id when joined).
    - Each tool of a Router session is mounted by Extras. `ToolRun` posts the terminal event of each run (thrown error -> `failed`, mount timeout -> `timedOut`, cancel -> `cancelled`). The Router journal sends each terminal as `runSettled` live. Thus a real test can make a failed inline run with a `BackgroundTool` that has `ToolMount(mode: .background, timeout:)` and a body that waits.
    - `PromptExecution.run` reads the session follow-up after the caller stream, so a background settlement after the answer also goes through the same projection.
    - `PromptToolCalls` (close of unfinished calls) merges the sent updates with `SessionMergeEngine`. An update with no status keeps the terminal status, so the close logic stays correct when the SDK updates omit status.
    - Test reader plan: `SessionMergeEngine(replaying:)` gives the status on the client.
  timestamp: 2026-10-11T03:20:25.380941+00:00
- actor: claude-code
  id: 01m4mg04rcnqtvh6s3f0hesxtr
  text: |-
    RED done. New suite `SettledRunStatusProjectionTests`: 4 tests fail for the expected cause (statuses after the settlement), the no-settlement test and the real background test pass.

    Real event order found (scripted backend, real Router session, tools mounted by Extras):
    - Inline run (BackgroundTool, mount timeout 0.2 s, settles `timedOut` inside the 6 s settle period): run progress (`in_progress`) -> `runSettled` (`failed`) -> text delta -> SDK `toolCall` (`in_progress`) -> SDK `toolStatus` running (`in_progress`) -> SDK `toolStatus` completed (`completed`, content + rawOutput). Router derives `completed` because the call has an output. Thus the client ended `completed` before the fix. The SDK events come when the transcript diff of the pass goes out, after the text of the model.
    - Background run (settle period 0, fails after 300 ms): run progress -> text delta -> SDK `toolCall` -> `toolStatus` running -> `toolStatus` completed -> `runSettled` (`failed`, after the answer, from the session follow-up). The settlement comes last, so the background path was already correct.
    Dead end: the first background test looped. The scripted backend plays the same script on each pass, and the mail of the settled run starts a new answer that called the tool again (31 s). Fix: `.onPrompt(containing:)` on the caller prompt, and `RoutedPrompt` sets the prompt text through `PromptExecution.modelPrompt`.
  timestamp: 2026-10-11T03:27:13.164012+00:00
- actor: claude-code
  id: 01m4mgqnz5xqvvsma7yc50pn00
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/SettledRunStatusProjectionTests.swift (new, 6 tests), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift (`RoutedPrompt`, `wireStatuses(ofToolCall:)`, `clientStatus(ofToolCall:)`), Tests/FoundationModelsACPAgentTests/RunProgressTests.swift (uses `RoutedPrompt`, no copy of the session setup).
    - design: `settledToolCallIds` in `EventProjection`, filled by `projectSettlement` with the wire id from `runCallId` (the `RunCallJoinTable`, no second join map). `sdkStatusPatch(for:status:)` gives `.unchanged` for a settled id. `projectToolStatus` sends nothing when status, content and rawOutput are all unchanged. Every settlement status counts, also an extension status such as `_lost`, because the settlement is the end of the run.
    - tests: root `swift test --scratch-path .build/alt --force-resolved-versions`: 901 tests in 98 suites passed, 1 known issue (the `withKnownIssue` in HarnessSmokeTests, as before), 0 warnings. IntegrationTests: 35 tests in 13 suites passed. Flaky ^05rmb1p did not occur.
    - next: /review
  timestamp: 2026-10-11T03:40:04.453706+00:00
- actor: claude-code
  id: 01m4mh7r2q3rarms9t87w2aye9
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (375f4a2): 1 finding (1 confirmed, 0 refuted). Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift:598 `reuse/reuse`. Acceptance: the 2 items are met. `swift test --scratch-path .build/alt --force-resolved-versions --filter "SettledRunStatusProjectionTests|RunProgressTests"`: 14 tests in 2 suites pass.
    - next: Extract one shared helper for wireStatuses(ofToolCall:) and lastWireTitle(ofToolCall:), then review again.
  timestamp: 2026-10-11T03:48:50.903793+00:00
- actor: claude-code
  id: 01m4mhb4sc72k90bf9mcz4w0ec
  text: |-
    ### implement — changed
    - finding fixed: `ProjectionTestSupport.swift` now has one helper `wireStrings(ofToolCall:key:)`. `lastWireTitle(ofToolCall:)` is its `.last` for `title`, and `wireStatuses(ofToolCall:)` is its full array for `status`. Finding box checked.
    - evidence: `swift test --scratch-path .build/alt --force-resolved-versions --filter "SettledRunStatusProjectionTests|RunProgressTests|ToolCallJoinProjectionTests|EventProjection"` with a new empty SKILLS_MARKETPLACE_CACHE: 62 tests in 4 suites passed, 0 failures, 0 warnings.
    - next: /review
  timestamp: 2026-10-11T03:50:42.220159+00:00
position_column: review
position_ordinal: '80'
title: 'Keep the terminal status of a settled run: the later SDK toolCall and toolStatus updates must not write over it'
---
## Problem

Found during ^w7hzpmq. After ^e1yq4gh, the SDK `toolCall` and `toolStatus` events of a call go on the same wire id as the run events of that call. The SDK `toolCall` event comes after the SDK call returned, thus after the settlement of an inline run. `EventProjection.projectToolCall` always sends `status: in_progress`, and `projectToolStatus` then sends the status that Router derives from the transcript (`running`, then `completed`).

Thus a run that settled `failed` (for example `timedOut`) or `cancelled` can end on the client as `completed`. Between the two updates, the client also shows `in_progress` for a run that is done.

## What to change

- Find the order of the events for an inline run and for a background run from a real Router stream (a test with the scripted backend).
- When the wire call has a terminal status from a settlement, the SDK `toolCall` and `toolStatus` updates must not send a status over it.
- Keep the current behavior for a call that no run settled.

## Real event order (found with the scripted backend and a real Router session)

- Inline run (a `BackgroundTool` with a mount timeout of 0.2 s, which settles `timedOut` inside the settle period of 6 s): run progress (`in_progress`) -> `runSettled` (`failed`) -> text delta of the model -> SDK `toolCall` (`in_progress`) -> SDK `toolStatus` running (`in_progress`) -> SDK `toolStatus` completed (`completed`, with content and rawOutput). Router sends the SDK events when the transcript diff of the pass goes out. Router derives `completed` because the call has an output, also when the run failed.
- Background run (settle period 0, the run fails after 300 ms): run progress -> text delta -> SDK `toolCall` -> SDK `toolStatus` running -> SDK `toolStatus` completed -> `runSettled` (`failed`, from the session follow-up after the answer). The settlement comes last, so this path was already correct.

## Design (as done)

`EventProjection` keeps `settledToolCallIds`: the wire id (from `RunCallJoinTable` through `runCallId`) of each call whose settlement sent the terminal status. After that, `projectToolCall` and `projectToolStatus` send no `status` for that id (`sdkStatusPatch(for:status:)`). They still send their other fields. A `toolStatus` update that then has no content and no raw output is not sent. A call with no settlement keeps the SDK statuses.

## Acceptance

- [x] A test reads the wire messages: an inline run that settles `failed`, then the SDK `toolCall` and `toolStatus` events, ends `failed` on the client.
- [x] A call with no settlement still ends with the status of `toolStatus`.

## Review Findings (2026-10-10 22:40)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift:598` `reuse/reuse` — The new wireStatuses(ofToolCall:) repeats the same pipeline as lastWireTitle(ofToolCall:). Both map each update to a wire object, filter by toolCallId, and read one string key. The only difference is the key and the last-or-all choice. The second copy diverges from the first and must be fixed twice. Extract a shared helper, for example wireStrings(ofToolCall:key:), that returns the string values of one key for each update of the call. Then define lastWireTitle as its .last and wireStatuses as the full array, so both use one implementation.