---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7d2wgjfja9aqy0k7b779c32
  text: 'The block is resolved. The FoundationModelsMultitool change is pushed: main 95856ed8 (Multitool card ^hqzpwwx). Under an ambient ToolContext, `MCPTool.call(arguments:)` posts one display event `.contentChunk(.json(...))` with the ordered MCP content blocks of a result that has a block that is not text. `MCPToolContent(display:)` decodes it. Work starts now.'
  timestamp: 2026-11-14T13:10:27.151148+00:00
- actor: claude-code
  id: 01m7d38khnw2wdfh169qfadw46
  text: |-
    Research and implementation notes:
    - `swift package update FoundationModelsMultitool` resolves main at 8ab15aad (the root and IntegrationTests). 95856ed8 is an ancestor of it. Package.swift pins by branch, thus it does not change.
    - MCPTestServer of Multitool has no tool that gives an image. Thus the test posts the display event in the form that MCPTool posts: `MCPToolContent(content:isError:).display` as `.contentChunk`.
    - `ACPEventTranslator.projectDisplay` was the only consumer of `.contentChunk` / `.contentReplace` / `.json`. A new private `displayItems(for:run:)` tries `MCPToolContent(display:)` first. Each MCP block becomes one item through `PromptContent.toolCallContent(from:)` (now it has a production caller). Each other part goes through the old `displayItem(for:run:)` and `isKept(_:)`, with no change.
    - A chunk with N items sends N `tool_call_content_chunk` updates, in order. The call keeps the MCP items (KeptDisplayItems), thus the completion `toolStatus` replace gives: MCP items first, then the text result.
    - The resume replay reads the recorded wire updates through SessionMergeEngine. A test shows that the replay gives the same content as the live updates. No change in SessionHistory was necessary.
    - ARCHITECTURE.md does not describe tool call content. No update.
  timestamp: 2026-11-14T13:17:03.413210+00:00
- actor: claude-code
  id: 01m7d38pc4ewgqaswb0zrwedfs
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift, Tests/FoundationModelsACPAgentTests/McpImageToolResultTests.swift (new, 4 tests: text+image, two images in order, text-only unchanged, replay equal). RED: 3 of 4 failed before the change (the text-only test is a guard of the unchanged behavior). `swift build --build-tests`: 0 new warnings. `timeout 900 swift test`: 2098 tests in 225 suites passed, 1 known issue (the old withKnownIssue in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: exit 0.
    - next: /review. Not committed. After the push, send the card id and the commit sha to testudoapp-75.
  timestamp: 2026-11-14T13:17:06.308881+00:00
- actor: claude-code
  id: 01m7d3ayw9zgebqz7fqsct9s3y
  text: |-
    ### test — green
    - evidence: swift test — 2098 tests in 225 suites passed, 1 known issue (HarnessSmokeTests, intended withKnownIssue), 0 failures. swift build --build-tests --package-path IntegrationTests — Build complete, 0 compiler warnings. Only the SwiftPM line "missing creator for mutated node" showed (build system, not a compiler warning).
    - next: review
  timestamp: 2026-11-14T13:18:20.553735+00:00
position_column: doing
position_ordinal: '80'
title: The image blocks of an MCP tool result go to the client in the tool call content
---
## What
Request from TestudoApp ^v30ggjj (Step 2). Decision of the user: the image of an MCP tool result goes into the tool call content (the `tool_call_update` content of ACP). It does not go into the agent message.

Now: `PromptContent.contentBlock(from:)` and `PromptContent.toolCallContent(from:)` (Sources/FoundationModelsACPAgent/Agent/PromptContent.swift:220-229) have no production caller. Only PromptContentTests calls them. The MCP result comes to ACPAgent only as text, because FoundationModelsMultitool renders an image as `[image: <mimeType>]`.

BLOCKED: this task waits for a FoundationModelsMultitool change. The session foundationmodelsmultitool-2a makes an MCP tool keep the structured content of its result, and it sends the API when the change is pushed. Do not start before that.

Then:
- Update the Multitool pin in Package.swift (Package.resolved is gitignored).
- Find the path from the MCP tool result to the `toolStatus`/`toolOutput` projection (`projectToolStatus(id:status:summary:output:)` and `contentPatch(summary:output:)` in Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift). Carry each image block (data and mimeType) to the tool call update, as a `ToolCallContent.content` item made with `PromptContent.toolCallContent(from:)`, next to the text content that is sent now.
- Keep the replay of a resumed session (SessionHistory, SessionResumeReplay) the same as the live update, if the transcript keeps the image.

## Acceptance Criteria
- [ ] A fake MCP tool result with a text block and an image block makes a tool call update whose content has the text item and one image item with the same data and mimeType.
- [ ] A result with two images gives two image items, in order.
- [ ] A result with no image gives the same update as before.
- [ ] `PromptContent.toolCallContent(from:)` has a production caller.

## Tests
- [ ] A new test in Tests/FoundationModelsACPAgentTests (for example, McpImageToolResultTests.swift) with a fake MCP tool result that holds an image. It asserts on the `tool_call_update` that the client records.
- [ ] `swift test` passes with 0 failures and 0 new warnings; `swift build --build-tests --package-path IntegrationTests` passes.

## Workflow
- Use `/tdd`: write failing tests first, then implement to make them pass.
- After the push, send the card id and the commit sha to testudoapp-75. #step2