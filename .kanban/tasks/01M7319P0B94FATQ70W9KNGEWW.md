---
assignees:
- claude-code
depends_on:
- 01M73040J7Q5AB7PRADXFEAMNV
- 01M7303F2AJEEVCV4EB76XDPW1
position_column: todo
position_ordinal: '8680'
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