---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q72seye8f8j0dw0sy0d6a7
  text: |-
    Research done.
    - EvaluationTests/ is not a tracked package now. The folder holds only an old `.build` and a `Package.resolved`, and `git ls-files EvaluationTests` gives nothing. The card parts about EvaluationTests do not apply.
    - `.github` does not name `PromptTurnTests`, and CIWorkflowTests does not name it. No CI selector changes.
    - Baseline `swift test`: 615 tests in 70 suites passed, 1 known issue. No compiler warning (one SwiftPM "missing creator for mutated node" note from the mlx bundle, which is not a compiler warning).
    - The acceptance regex does not find `turnUpdates`, `turnCount`, `turnDeadline`, `holdsATurnUpdate` and the local `turn` variables. I rename them too, because the card lists them.
    - `ScriptedTurnStep.endTurn` is a scripted step that ends one model pass. It is not the ACP `StopReason.endTurn`. I rename it to `.endPass`. The ACP words `endTurn` (StopReason), `end_turn`, `maxTurnRequests`, `endTurnExitCode`, `endTurnWireValue` and `...EndTurnStopReason` stay.
    - `theSDKSwitchTurnsTheExportOff` uses "turns" as a verb (to turn off). It stays.
  timestamp: 2026-09-29T18:33:24.190335+00:00
- actor: claude-code
  id: 01m3q7d9a35eh14h5hcj07gxqn
  text: |-
    ### implement — changed
    - evidence: `swift test`: 615 tests in 70 suites passed, 1 known issue. This is the same as the baseline (615). There are no compiler warnings. The only other output is the old SwiftPM note "missing creator" for the mlx bundle. `swift build --build-tests` in `IntegrationTests/`: Build complete, with no warnings. Acceptance: `rg -n "[a-z]Turn[A-Z]|\bTurn[A-Z]|[a-z]Turns?\b" Tests IntegrationTests` gives 61 lines. Each line is an ACP word: `StopReason.endTurn`, `endTurnExitCode`, `endTurnWireValue`, `maxTurnRequests`, `...EndTurnStopReason`, `aScriptedEndTurnExitsSuccess`, or `"case .endTurn: .success"`.
    - Files: 3 renames with `git mv`: Support/ScriptedTurnFixture.swift → Support/ScriptedPromptFixture.swift, PromptTurnTests.swift → PromptExecutionTests.swift, and Support/ComposedTurnFixture.swift → Support/ComposedPromptFixture.swift. Also changed: TestSupport ScriptedModel.swift, QueuedScriptedModel.swift, AssertionHelpers.swift, Harness.swift and RecordingClient.swift. The call sites in Tests/ and IntegrationTests/ are updated too (about 45 files). The Name Table section in the description gives the full list of names.
    - Method: I did the identifier renames with a whole-word perl map. For `.endTurn` → `.endPass`, I changed only the uses in step arrays. The compiler then checked that no `StopReason.endTurn` changed. The build gave zero errors.
    - Doc comments: I updated the doc comments that name a renamed symbol or that describe a renamed helper. In ScriptedModel.swift, "turn" becomes "pass" for one play of the script, and "prompt" for the agent unit.
    - Not in scope: about 330 lines of comments and string literals in Tests/ and IntegrationTests/ still say "turn". Examples are the prompt texts `"first turn"` and `"Run the scripted tool turn"`. Task ^yxmr32k now tracks that work.
    - next: review
  timestamp: 2026-09-29T18:39:08.099813+00:00
depends_on:
- 01M3A32E8EVDZ16ZQ8QF9513F2
- 01M3A32KQB5RFWNGX6M258Q0H3
position_column: doing
position_ordinal: '8180'
title: Rename the "turn" names of the test support and the test files to "prompt"
---
## Why

The rule of the plan: "prompt" is the agent unit; "request / attempt / pass" are Router units; "turn" stays only for ACP protocol words. The test support has the most "turn" names (measured 2026-09-24): `ScriptedTurnFixture` 163, `ScriptedTurnStep` 25, `makeSinkedTurn` 21, `turnUpdates` 10, `makeToolTurnScript` 9, `runToolTurn` 9, `ComposedTurnFixture` 7, `driveTurn` 5, `runTwoTurns` 5, `runScriptedTurn` 4, `runOneTurn` 4, `turnCount`, `seedTurnCount`, `firstTurn`, `eventsAfterFirstTurn`, `eventsAfterSecondTurn`, `ofTurnPlaying`, `uncancelledTurnKinds`, `PromptTurnTests`.

## What

1. Rename the types and helpers in `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift` (file → `ScriptedPromptFixture.swift` with `git mv`), `Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift`, and `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`. Use "prompt" for an agent unit, and "pass" for one scripted model generation if a helper counts generations.
2. Rename `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift` to `PromptExecutionTests.swift` (with `git mv`) and its suite name.
3. Update the call sites in `Tests/`, `IntegrationTests/`, and `EvaluationTests/` (`rg -n "Turn" Tests IntegrationTests EvaluationTests`).
4. Update the CI suite selectors if one names a renamed suite (`rg -n "PromptTurnTests" .github`).

Note (2026-09-29): `EvaluationTests/` is not a package in the repository now (it was removed; the folder holds only an untracked `.build` and `Package.resolved`). The parts of this card about `EvaluationTests/` do not apply.

## Name Table

| Old name | New name |
|---|---|
| `ScriptedTurnFixture` (file `Support/ScriptedTurnFixture.swift`) | `ScriptedPromptFixture` (file `Support/ScriptedPromptFixture.swift`) |
| `ComposedTurnFixture` (file `Support/ComposedTurnFixture.swift`) | `ComposedPromptFixture` (file `Support/ComposedPromptFixture.swift`) |
| `ComposedTurnFixture.Turn` | `ComposedPromptFixture.Outcome` |
| `PromptTurnTests` (file and suite) | `PromptExecutionTests` |
| `ScriptedTurnStep` | `ScriptedPassStep` |
| `ScriptedTurnStep.endTurn` (the scripted step) | `ScriptedPassStep.endPass` |
| `ScriptedSessionBackend.playTurn` | `playPass` |
| `ResumeSessionFixture` backend `appendTurn` | `appendPass` |
| `ResumeSessionFixture.completedTurnCount` | `completedPromptCount` |
| `makeSinkedTurn` → `(turn:, recorder:)` | `makeSinkedExecution` → `(execution:, recorder:)` |
| local `turn` (a `PromptExecution`) | `execution` |
| local `turn` (a `ComposedPromptFixture.Outcome`) | `outcome` |
| `makeToolTurnScript` (fixture and `TierTwoTests`) | `makeToolPromptScript` |
| `toolTurnScript` | `toolPromptScript` |
| `turnUpdates(in:)` | `promptUpdates(in:)` |
| `lastTurnUpdate` | `lastPromptUpdate` |
| `holdsATurnUpdate` | `holdsAPromptUpdate` |
| `driveTurn` | `drivePrompt` |
| `runTwoTurns` | `runTwoPrompts` |
| `runToolTurn` | `runToolPrompt` |
| `runNoteTurn` | `runNotePrompt` |
| `runScriptedTurn` | `runScriptedPrompt` |
| `runOneTurn` | `runOnePrompt` |
| `eventsAfterFirstTurn`, `eventsAfterSecondTurn` | `eventsAfterFirstPrompt`, `eventsAfterSecondPrompt` |
| `afterFirstTurn`, `afterSecondTurn` | `afterFirstPrompt`, `afterSecondPrompt` |
| `firstTurn`, `secondTurn`, `bothTurns` | `firstPrompt`, `secondPrompt`, `bothPrompts` |
| `exitCode(ofTurnPlaying:)` | `exitCode(ofPromptPlaying:)` |
| `uncancelledTurnKinds` | `uncancelledPromptKinds` |
| `seedTurnCount` (seed transcript prompt/response pairs) | `seedPassCount` |
| `turnCount` and loop `turn` (direct `session.respond` calls) | `requestCount` and loop `request` |
| `turnDeadline` | `promptDeadline` |
| Test functions with "Turn" for the agent unit (for example `aCancelledTurnExitsFour`) | "Prompt" (for example `aCancelledPromptExitsFour`) |
| Test functions with "ModelTurn" or "TurnEnd" for one model generation | "ModelPass", "PassEnd" |

The ACP protocol words stay: `StopReason.endTurn`, `end_turn`, `maxTurnRequests`, `endTurnExitCode`, `endTurnWireValue`, `...EndTurnStopReason`, `aScriptedEndTurnExitsSuccess`. The verb in `theSDKSwitchTurnsTheExportOff` stays.

## Acceptance Criteria

- [x] `rg -n "[a-z]Turn[A-Z]|\bTurn[A-Z]|[a-z]Turns?\b" Tests IntegrationTests EvaluationTests` shows only ACP protocol words (`endTurn`, `maxTurnRequests`).
- [x] The test count of `swift test` is the same before and after.
- [x] The integration and evaluation packages build (`swift build --build-tests` in `IntegrationTests/` and `EvaluationTests/`). (`EvaluationTests/` does not exist now.)

## Tests

- [x] No new behavior. The current suites are the proof.
- [x] Run `swift test` at the root, and `swift build --build-tests` in `IntegrationTests/` and `EvaluationTests/`. All pass.

## Workflow
- Use `/tdd` — for a rename, the green suite before and after the change is the test. #generation-queue