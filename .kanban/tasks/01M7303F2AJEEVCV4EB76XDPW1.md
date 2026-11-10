---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7306vcegtwy9fmp5788gpsa
  text: 'Decision from testudoapp-75 (2026-11-10): each agent has this style, and sub-agent runs are included. If a sub-agent run builds its instructions outside InstructionsAssembler, give it the same StyleInstructions.text first, and add a test for it. If that change is large (for example a new API in FoundationModelsAgents), stop and report it to testudoapp-75 first. testudoapp-75 will decide.'
  timestamp: 2026-11-10T15:11:15.854935+00:00
depends_on:
- 01M7302TV19EE0H603MP21Q32S
position_column: todo
position_ordinal: '8380'
title: 'ACPA-20: Built-in style instructions — short answers in Simplified Technical English, before AGENT.md and AGENTS.md'
---
## What
Spec: ACPA-20 (TestudoApp/features/packages/foundationmodels-acpagent.md). Decision D153.

1. New `Sources/FoundationModelsACPAgent/Instructions/StyleInstructions.swift`: a `public enum StyleInstructions` with `static let text`. The text tells the agent:
   - Write answers in ASD-STE100 Simplified Technical English: short sentences, one instruction in each sentence, the active voice, one meaning for each word.
   - Keep code, commands, file paths, identifiers and quoted text as they are.
   - Give the answer first. No preamble. Do not repeat the question. Do not give a summary that the user did not ask for. A long answer is only for a request that needs it, for example a plan or a report.
2. `Sources/FoundationModelsACPAgent/Instructions/InstructionsAssembler.swift` `assemble`: put `StyleInstructions.text` first, before the base prompt (the session agent of ACPA-1a, the default agent, an `Instructions.md`, or `BuiltinInstructions`) and before the `AGENTS.md` text. It is there for every agent, also when an `Instructions.md` replaces the base prompt.
3. Remove the "Answers" text of `BuiltinInstructions.text` that the style text now gives, so the two texts do not disagree.
4. Sub-agent runs: check if the instructions of a run (FoundationModelsAgents) also go through this assembler. If not, record that in the task comment and in the reply to `testudoapp-75`; the spec text is about the session.
5. The README links to the text, the same as for `BuiltinInstructions` (`DocumentationSyncTests`).

## Acceptance Criteria
- [ ] The instructions of each new session start with `StyleInstructions.text`.
- [ ] The style text comes before the agent text and before the `AGENTS.md` text, for a named agent, a `cwd` `AGENT.md`, the default agent, an `Instructions.md` and the builtin floor.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift`: for each of the five base prompt cases, the assembled text starts with `StyleInstructions.text`, and the `AGENT.md` and `AGENTS.md` text comes after it.
- [ ] A session test composes a session and confirms that its instructions start with the style text.
- [ ] `DocumentationSyncTests` checks the README link.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1