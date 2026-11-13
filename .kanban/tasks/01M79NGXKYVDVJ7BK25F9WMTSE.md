---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79nnqm8b9w0xdwr15pgyfhb
  text: |-
    Research (implement step):
    - Pin: Package.resolved pins Multitool 9d46b0fa. b3d7b13e is an ancestor of it, so the files tool already emits `.diff`. No pin move is necessary.
    - Cause: in `ACPEventTranslator`, a display `.contentChunk(.diff)` goes as a `tool_call_content_chunk` (the client appends it). Later updates of the same wire call send `content` as a full replace: the SDK `toolStatus` (`contentPatch(summary:output:)`), the run progress (`projectProgress`), the attachment report (`projectToolCallReport`) and the settlement (`projectSettlement`). Each replace drops the diff. For a runCode call, the last replace is the SDK `toolStatus` with the text output.
    - Same loss for the terminal kind: the settlement of a shell run sends `[terminal, notes]`, and the SDK `toolStatus` that comes after an inline settlement replaces it with text only.
    - Images: `ToolDisplayContent` has only text, json and diff, and a `SegmentPayload` attachment rides as text. Thus no image item exists to lose.
    - History and replay: `SessionMergeEngine` folds `tool_call_update` content as a replace and appends `tool_call_content_chunk`. Thus a correct final update from the translator also gives a correct merged history and replay.
    - Plan: keep the diff items of the display events and the terminal item of the settlement per wire tool call id (bounded, with `BoundedTable`). Each later content replace that is not a display event sends the kept items first, then its own items. A replace that adds no item sends no `content` field. Text and json display parts are not kept: a later replace replaces them, as before.
  timestamp: 2026-11-13T05:21:50.216792+00:00
- actor: claude-code
  id: 01m79p8k0wtqee387rntdgffq6
  text: |-
    Implementation landed (not committed).
    - New `KeptDisplayItems` (Sources/FoundationModelsACPAgent/Agent/KeptDisplayItems.swift): per wire tool call id, a `BoundedTable` (limit 256 calls) of the items that the call keeps to its end. `content(for:adding:)` gives the kept items, then the result items. With kept items, a result with no item gives `.unchanged` (no `content` field). With no kept item, the result stays as before.
    - `ACPEventTranslator`: a display `.contentChunk(.diff)` adds its item. A display `.contentReplace` sets the kept items to its diff parts only (the tool replaced the whole content). The settlement adds its `Terminal` item. The SDK `toolStatus`, the progress, the attachment report and the settlement send the kept items first.
    - Text and json display parts are not kept: a later replace replaces them, as before. Thus ToolDisplayProjectionTests stays as it is.
    - Terminal: the same loss occurred (inline shell settlement `[terminal]`, then SDK `toolStatus` text replaced it). Corrected and tested. Images: no image display kind exists, so no loss.
    - History and replay: no change was necessary. `SessionMergeEngine` merges the corrected updates, and the replay test confirms the diff stays.
    - Not done here: the request "tell testudoapp-75". The GalleryScriptTests known issue in TestudoApp (825c8e8 of ^g6ymedq) fails when this fix lands. I did not edit or write to the sibling repository, so the orchestrator must tell testudoapp-75.
    - Found: a timing failure in SubagentMessageWireTests under high machine load. New card ^3hvxfd4.
  timestamp: 2026-11-13T05:32:08.092183+00:00
- actor: claude-code
  id: 01m79p8sj7jtvmn2qdcefrd8xh
  text: |-
    ### implement — changed
    - evidence: cause = full content replaces after a diff chunk (SDK toolStatus, progress, attachment report, settlement) in ACPEventTranslator. Files: Sources/FoundationModelsACPAgent/Agent/KeptDisplayItems.swift (new), Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift, Tests/FoundationModelsACPAgentTests/KeptDisplayItemsTests.swift (new, 9 tests), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift (`clientContent(ofToolCall:)`). RED: `swift test --filter KeptDisplayItemsTests` 7 of 9 failed (the 2 that passed are the "ends as before" and "tool replace" guards). GREEN: 9 of 9 passed. Full `timeout 900 swift test` (log written to a file): run 1 had 2051 tests, 0 failures, 1 known issue that already existed (HarnessSmokeTests withKnownIssue). Run 2, after a refactor that keeps the behavior (one `displayItem` map in the display replace), had 2051 tests and 1 failure: SubagentMessageWireTests `theFinalViewComesBeforeTheFinalStatus` (`view → nil`) at load average about 17. That suite alone passed, 11 of 11. It has no relation to this change. New card ^3hvxfd4. Zero compiler warnings. The only warning is the SwiftPM build-system line "missing creator for mutated node" for the mlx bundle, which already existed. `swift format lint` is clean. Pins: Multitool stays at 9d46b0fa, which already includes b3d7b13e. I made no pin move.
    - next: test step (full `swift test` on a machine that is not under load), then review. Tell testudoapp-75 that the GalleryScriptTests known issue (TestudoApp 825c8e8) will fail.
  timestamp: 2026-11-13T05:32:14.791945+00:00
position_column: doing
position_ordinal: '8280'
title: The completion of a runCode call keeps the diff items that the call emitted
---
## What
Report of testudoapp-75 (2026-11-12), user-visible. With Multitool b3d7b13e (or later) the files tools emit a `.diff` display event, and `ACPEventTranslator` sends it as a `diff` content item while the `runCode` call runs. But the update that completes the `runCode` call (seen on 74eea0a) replaces the whole `content` of the tool call with its text result only. The client sees the content kinds `other` -> `other,diff` -> `other`, so the finished tool call has no diff, and the chat never shows the change.

Wanted: the completion keeps the display items that the call emitted (the diff items, in their order), and adds the text result after them. If the result adds nothing new, the final update sends no `content` field (ACP: an absent field keeps the content). TestudoApp marks the problem as a known issue in GalleryScriptTests (TestudoApp 825c8e8 of ^g6ymedq), so that test fails when this fix lands; tell testudoapp-75.

1. Find where the completion update of a tool call is built (Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift, PromptToolCalls.swift, or the tool call update path) and how display items (`diff`) are sent during the call.
2. Keep the emitted display items of the call (per tool call id), and build the final `content` as those items plus the text result. Also check the replay and the merged history (SessionMergeEngine merges tool_call_update content): the final merged state must hold the diff too.
3. Check other display kinds (for example terminal or images) for the same loss.

## Acceptance Criteria
- [x] A runCode call that writes a file ends with `content` that holds the `diff` item, then the text result.
- [x] The replay of a session gives the same final content (the diff stays).
- [x] A call with no display item ends as before.

## Tests
- [x] A test with a runCode call that writes a file (the files tool emits the diff): the final tool_call_update content holds the diff item, then the text. Write it first and see it fail.
- [x] A replay test for the same call.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1