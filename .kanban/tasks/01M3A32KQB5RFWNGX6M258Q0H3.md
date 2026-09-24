---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Rename the "turn" types of the acp-agent CLI to "prompt"
---
## Why

The rule of the plan (see the library rename task): "prompt" is the agent unit, "turn" stays only for ACP protocol words. The CLI target `Sources/acp-agent` has its own "turn" names.

## What

Proposed names (the implementer can propose better names in a comment first):

| Now | New |
|---|---|
| `RunTurn` (`Sources/acp-agent/RunTurn.swift`) | `RunPrompt` (file `RunPrompt.swift`, with `git mv`) |
| `RunTurnResult` | `RunPromptResult` |
| `runTurn` | `runPrompt` |
| `OutOfProcessTurn` | `OutOfProcessPrompt` |

1. Rename in `Sources/acp-agent/RunTurn.swift`, `Sources/acp-agent/RunCommand.swift`, and each other file that `rg -n "RunTurn|runTurn|OutOfProcessTurn" Sources Tests` finds.
2. Update the tests that call them (`Tests/FoundationModelsACPAgentTests/RunCommandTests.swift` and others from the same `rg`).
3. Do not change user-visible CLI output or exit codes. If a message says "turn" for the agent unit, change the word to "prompt", and update the test that reads the message.

## Acceptance Criteria

- [ ] `rg -n "RunTurn|runTurn|OutOfProcessTurn" Sources Tests` gives no result.
- [ ] The exit code table and the stdout contract do not change.
- [ ] `swift build` and `swift test` pass.

## Tests

- [ ] No new behavior. The current `RunCommandTests` and `CLIProcessTests` are the proof.
- [ ] Run `swift test`. All pass, with the same test count as before.

## Workflow
- Use `/tdd` — for a rename, the green suite before and after the change is the test. #generation-queue