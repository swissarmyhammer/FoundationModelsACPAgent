---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73fk03gydssb77yjh2ya0st
  text: 'Research: The resume path (`SessionResume.swift` `composeResumedSession`) calls `composeSession(..., resuming:)` in `SessionSetup.swift`. Thus one change in `composeSession` gives the section to a new session and to a resumed session. A replay-only resume assembles no instructions; it keeps the recorded text. The plan: a new `OpenTestudoInstructions` enum in `Instructions/` holds the section text. `InstructionsAssembler.init` gets `toolMode` and `openTestudoDownloadURL` (both with defaults). `assemble` puts the section after `StyleInstructions.text` and before the base prompt, in `sandboxed` mode only. `RoutedACPAgent` keeps `openTestudoDownloadURL` beside `toolMode`.'
  timestamp: 2026-11-10T19:40:02.544588+00:00
- actor: claude-code
  id: 01m73grk3bjj4znc92fq4ys333
  text: |-
    ### implement — changed
    - evidence: commit 329793c on branch par/9kngeww (worktree agent-a15e1549c830c8850). Files: Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift (new), Instructions/InstructionsAssembler.swift, RoutedACPAgent.swift, ComposedAgent.swift, Agent/SessionSetup.swift, README.md, Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift, Tests/FoundationModelsACPAgentTests/ToolModeTests.swift, Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift. RED: the test build failed with "extra argument 'openTestudoDownloadURL'". Full `swift test`: 1927 tests in 211 suites passed, 1 known issue (the deliberate one in HarnessSmokeTests, there before this change), zero compiler warnings. After a format edit, `swift test --filter "InstructionsAssemblerTests|ToolModeTests"`: 64 tests passed.
    - notes: SessionResume.composeResumedSession calls composeSession, so the one change in composeSession serves the new and the resumed session. SessionResume.swift did not need an edit. A replay-only resume keeps the recorded instructions, as before. The ToolModeTests resume test does new, close, resume with direct calls on the composed agent; it needs no prompt.
    - next: review
  timestamp: 2026-11-10T20:00:34.411569+00:00
- actor: claude-code
  id: 01m73h47rgaqtd93z2ammq47yr
  text: |-
    ### review — findings
    - evidence: review sha 329793c~1..329793c — 2 findings (2 confirmed, 0 refuted): Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift:275, Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:106. Five code-hygiene tool rules could not read Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, because the MCP server runs in the main working tree and the file is only in the worktree.
    - next: declare `openTestudoDownloadURL` one time in Tests/FoundationModelsACPAgentTestSupport and use it from the two test files; then review again.
  timestamp: 2026-11-10T20:06:56.016436+00:00
depends_on:
- 01M73040J7Q5AB7PRADXFEAMNV
- 01M7303F2AJEEVCV4EB76XDPW1
position_column: review
position_ordinal: '8180'
title: 'ACPA-19c: In sandboxed mode, the session instructions send work that needs a child process to OpenTestudo'
---
## What
Decision D128 (i): "In Testudo, the agent says that the work needs OpenTestudo and gives a link to its download page." Request from testudoapp-75 (2026-11-10). TestudoApp ^3czzrg4 gives the URL. This task is separate from ^xfeamnv (ACPA-19b) to keep each task small.

1. `Sources/FoundationModelsACPAgent/ComposedAgent.swift` `compose(...)` and the `RoutedACPAgent` init: add `openTestudoDownloadURL: URL? = nil`. Keep it with the mode in the agent state, so each session can read it.
2. `Sources/FoundationModelsACPAgent/Instructions/InstructionsAssembler.swift`: in `sandboxed` mode, add a short section to the session instructions. It says: work that needs a shell, a stdio MCP server, a skill script or code context needs OpenTestudo. Tell the user this and give the download URL. Write the text in ASD-STE100 Simplified Technical English. Put it after the style text of ACPA-20 and before the agent text. When the mode is `sandboxed` and the URL is `nil`, add the section with no link.
3. In `open` mode, the section is not in the instructions.
4. `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`: give the mode and the URL to the assembler. Do the same for the resume path (`SessionResume.swift` `composeResumedSession`).

## Acceptance Criteria
- [ ] In `sandboxed` mode with a URL, the session instructions have the OpenTestudo section and the URL.
- [ ] In `sandboxed` mode with no URL, the section is there with no link.
- [ ] In `open` mode, the instructions have no OpenTestudo section and no URL.
- [ ] A resumed session gets the same section as a new session.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift`: one test for each of the three mode and URL cases.
- [ ] `Tests/FoundationModelsACPAgentTests/ToolModeTests.swift`: compose an agent in `sandboxed` mode with a URL. Confirm that the instructions of a new session and of a resumed session have the URL.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1

## Review Findings (2026-11-10 14:01)

> Scope: `review sha 329793c~1..329793c` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsACPAgent/Instructions/OpenTestudoInstructions.swift, so its declarations are unread

- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift:275` `reuse/reuse` — The test constant `openTestudoDownloadURL` repeats the URL literal that ToolModeTests already defines. The same value lives in two places. Move the constant to shared test support, as in the finding for ToolModeTests.swift:106, and use the shared constant in this file.
- [ ] `Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:106` `reuse/reuse` — The test constant `openTestudoDownloadURL` repeats the same URL literal that another test file already defines. Two copies can drift apart, so a test of one file may not match the other. Declare the URL once in the shared test support, for example beside `composeStubAgent` in Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift, and reference it from both test files. Remove the private copy in ToolModeTests.swift.
