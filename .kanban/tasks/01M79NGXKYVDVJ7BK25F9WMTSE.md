---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The completion of a runCode call keeps the diff items that the call emitted
---
## What
Report of testudoapp-75 (2026-11-12), user-visible. With Multitool b3d7b13e (or later) the files tools emit a `.diff` display event, and `ACPEventTranslator` sends it as a `diff` content item while the `runCode` call runs. But the update that completes the `runCode` call (seen on 74eea0a) replaces the whole `content` of the tool call with its text result only. The client sees the content kinds `other` -> `other,diff` -> `other`, so the finished tool call has no diff, and the chat never shows the change.

Wanted: the completion keeps the display items that the call emitted (the diff items, in their order), and adds the text result after them. If the result adds nothing new, the final update sends no `content` field (ACP: an absent field keeps the content). TestudoApp marks the problem as a known issue in GalleryScriptTests (TestudoApp 825c8e8 of ^g6ymedq), so that test fails when this fix lands; tell testudoapp-75.

1. Find where the completion update of a tool call is built (Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift, PromptToolCalls.swift, or the tool call update path) and how display items (`diff`) are sent during the call.
2. Keep the emitted display items of the call (per tool call id), and build the final `content` as those items plus the text result. Also check the replay and the merged history (SessionMergeEngine merges tool_call_update content): the final merged state must hold the diff too.
3. Check other display kinds (for example terminal or images) for the same loss.

## Acceptance Criteria
- [ ] A runCode call that writes a file ends with `content` that holds the `diff` item, then the text result.
- [ ] The replay of a session gives the same final content (the diff stays).
- [ ] A call with no display item ends as before.

## Tests
- [ ] A test with a runCode call that writes a file (the files tool emits the diff): the final tool_call_update content holds the diff item, then the text. Write it first and see it fail.
- [ ] A replay test for the same call.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1