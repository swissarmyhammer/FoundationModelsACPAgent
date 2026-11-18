---
assignees:
- claude-code
depends_on:
- 01M7QCBBA8BX23JY4SFZX4K6R4
position_column: todo
position_ordinal: '8580'
title: 'D200: test that `skills: [sessions]` in AGENT.md puts the skill body in the instructions'
---
Decision D200 in `TestudoApp/features/decisions.md` (commit d1895ba). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-sessions-skill.md`, change item 3 and the third unit test.

## Dependency

^zx4k6r4 (the built-in layer of the skills stack).

## Current behavior

The `skills:` key already works for the session agent. `SessionSetup` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:1176-1195`) composes the session agent (`SessionAgentComposition.swift:91-102`) and gives `agent.text` to `InstructionsAssembler.assemble` (`Instructions/InstructionsAssembler.swift:162-185`). `agent.text` is the body of the agent, then the skill bodies. An `Instructions.md` replaces the base prompt and the skill bodies (`InstructionsAssembler.swift:219-231`); D200 keeps this.

## Change

Add tests only, if the code works. Do not change the preload code or `InstructionsAssembler`. If a test fails, fix the cause in this package.

## Tests

- A session with a default agent whose `AGENT.md` has `skills: [sessions]` gets the body of the skill in its instructions, after the body of the agent.
- A session with an agent that has no `skills:` key does not get the body.
- `runner.catalog()` gives no `unknownSkill` warning for `sessions`.
- With an `Instructions.md`, the skill body is not in the instructions, and the `skills` tool can still load the skill. #d200 #sessions-skill