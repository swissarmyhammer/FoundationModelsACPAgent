---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73detf7pd3axzc720yxm4m7
  text: 'foundationmodelsagents-d7 accepted the API as Agents task ^mpqd9de (step1), after ^1yb868r. `AgentEnvironment.make(..., instructionsPreamble: String? = nil, ...)`, stored as `public let instructionsPreamble: String?`. A run joins [preamble] + AGENTS.md documents + body + skill bodies with `instructionsSeparator`. A nil or whitespace-only preamble is left out. New runs and restored runs both get it. `sessionAgentInstructions(for:)` and `defaultAgentInstructions()` do not add it. Wait for the commit, then bump only the Agents pin.'
  timestamp: 2026-11-10T19:02:48.551129+00:00
depends_on:
- 01M7303F2AJEEVCV4EB76XDPW1
position_column: todo
position_ordinal: '9280'
title: 'ACPA-20b: Sub-agent runs start with the style text (AgentEnvironment instructionsPreamble)'
---
## What
Split from ^76xdpw1 (ACPA-20, D153) on 2026-11-10. testudoapp-75 decided that each agent, also each sub-agent run, gets the style text. A run makes its instructions in FoundationModelsAgents (`AgentSessionMaker.instructions(parts:in:)`), not in `InstructionsAssembler`.

External dependency: FoundationModelsAgents `AgentEnvironment.make(..., instructionsPreamble: String?)` (requested from foundationmodelsagents-d7 on 2026-11-10). Do not start until it is pushed.

1. Update only the FoundationModelsAgents pin.
2. `Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift` (~94): pass `instructionsPreamble: StyleInstructions.text` to `AgentEnvironment.make`.
3. Confirm that the main session does not get the text two times (`sessionAgentInstructions(for:)` does not add the preamble).

## Acceptance Criteria
- [ ] The instructions of a sub-agent run start with `StyleInstructions.text`, then the `AGENTS.md` text, then the agent body.
- [ ] A restored run starts with the same text.
- [ ] The main session has the style text one time.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/`: start a run through the `agents` tool with a working folder that has an `AGENTS.md`, and confirm the order of its instructions. Do the same for a restored run.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1