---
assignees:
- claude-code
depends_on:
- 01M3A32E8EVDZ16ZQ8QF9513F2
- 01M3A32KQB5RFWNGX6M258Q0H3
position_column: todo
position_ordinal: '8780'
title: Rename the "turn" names of the test support and the test files to "prompt"
---
## Why

The rule of the plan: "prompt" is the agent unit; "request / attempt / pass" are Router units; "turn" stays only for ACP protocol words. The test support has the most "turn" names (measured 2026-09-24): `ScriptedTurnFixture` 163, `ScriptedTurnStep` 25, `makeSinkedTurn` 21, `turnUpdates` 10, `makeToolTurnScript` 9, `runToolTurn` 9, `ComposedTurnFixture` 7, `driveTurn` 5, `runTwoTurns` 5, `runScriptedTurn` 4, `runOneTurn` 4, `turnCount`, `seedTurnCount`, `firstTurn`, `eventsAfterFirstTurn`, `eventsAfterSecondTurn`, `ofTurnPlaying`, `uncancelledTurnKinds`, `PromptTurnTests`.

## What

1. Rename the types and helpers in `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift` (file → `ScriptedPromptFixture.swift` with `git mv`), `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift`, and `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`. Use "prompt" for an agent unit, and "pass" for one scripted model generation if a helper counts generations.
2. Rename `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift` to `PromptExecutionTests.swift` (with `git mv`) and its suite name.
3. Update the call sites in `Tests/`, `IntegrationTests/`, and `EvaluationTests/` (`rg -n "Turn" Tests IntegrationTests EvaluationTests`).
4. Update the CI suite selectors if one names a renamed suite (`rg -n "PromptTurnTests" .github`).

## Acceptance Criteria

- [ ] `rg -n "[a-z]Turn[A-Z]|\bTurn[A-Z]|[a-z]Turns?\b" Tests IntegrationTests EvaluationTests` shows only ACP protocol words (`endTurn`, `maxTurnRequests`).
- [ ] The test count of `swift test` is the same before and after.
- [ ] The integration and evaluation packages build (`swift build --build-tests` in `IntegrationTests/` and `EvaluationTests/`).

## Tests

- [ ] No new behavior. The current suites are the proof.
- [ ] Run `swift test` at the root, and `swift build --build-tests` in `IntegrationTests/` and `EvaluationTests/`. All pass.

## Workflow
- Use `/tdd` — for a rename, the green suite before and after the change is the test. #generation-queue