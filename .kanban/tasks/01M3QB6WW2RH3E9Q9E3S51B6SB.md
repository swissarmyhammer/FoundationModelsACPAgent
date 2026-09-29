---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3qc6qp4qs6c218achanx2sd
  text: 'Research: no test in Tests/ or IntegrationTests/ uses `ScriptedPassStep.collectingToolCall`. Its only references are in ScriptedModel.swift. Thus the play is dead. Its private parts are also dead after removal: `ScriptedModelError.noRunToCollect`, `completionTokenField`, `SynthesizedTranscript.latestAnswer`, `invokeCollectingTool`, `latestCompletionToken`, `argumentsJSON(collecting:)`. `RecordedTranscriptFile.completionTokenKey` stays; RunCodeSourceTests uses it. No other line in Tests/ or IntegrationTests/ names a `wait` tool.'
  timestamp: 2026-09-29T20:02:56.324791+00:00
- actor: claude-code
  id: 01m3qcah1mk1bxrxma2b0xbv80
  text: |-
    ### implement — changed
    - evidence: ScriptedModel.swift — removed the dead play `ScriptedPassStep.collectingToolCall(name:)` and its private parts: `ScriptedModelError.noRunToCollect`, `completionTokenField`, `SynthesizedTranscript.latestAnswer`, `invokeCollectingTool(named:)`, `latestCompletionToken()`, `argumentsJSON(collecting:)`, the `latestAnswer` write in `invokeTool`, and the `noRunToCollect` line in the `play` Throws doc. RecordedTranscriptFile.swift — `completionTokenKey` doc now tells what the field is (it names the background run in the pending envelope, and equals the `correlationID` of the run's operation events), with no `wait` tool. `rg -n "\`wait\`" Tests IntegrationTests` gives no match. Each other `\bwait\b` hit is the English word. `swift test`: 615 tests in 70 suites pass, 1 known issue (the planned negative check in HarnessSmokeTests, which was already there), zero compiler warnings. `swift build --build-tests` in IntegrationTests/: build complete, zero compiler warnings. Both builds print the SwiftPM build graph line "missing creator for mutated node" for the mlx-swift_Cmlx bundle. That line is not a compiler warning, and this change did not cause it.
    - next: /review
  timestamp: 2026-09-29T20:05:00.596779+00:00
- actor: claude-code
  id: 01m3qcmqhwfx7hjzrgh812fbt0
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (546269e) gives 0 findings, 0 confirmed, 0 refuted. 2 files were reviewed. 4 `.kanban/` files were not reviewed because `.reviewignore` excludes them. The task had no earlier review findings. Acceptance: `rg -n "\`wait\`" Tests IntegrationTests` gives no match. `swift test` gives 615 tests in 70 suites that pass, with 1 known issue (the planned negative check in HarnessSmokeTests) and zero compiler warnings. The only `warning:` line is the SwiftPM build graph line "missing creator for mutated node" for the mlx-swift_Cmlx bundle. That line is not a compiler warning. Both acceptance boxes are now checked.
    - next: none. The task moves to done.
  timestamp: 2026-09-29T20:10:34.940347+00:00
- actor: claude-code
  id: 01m3qcn4t0jb017ges1ydf0zjw
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — ScriptedModel.swift, RecordedTranscriptFile.swift
    - test: green — swift test 615 tests pass
    - commit: 546269e
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-29T20:10:48.512764+00:00
position_column: done
position_ordinal: fb80
title: Remove the obsolete `wait` tool from the test support doc comments and the ScriptedModel collecting play
---
## Why

Multitool mounts no `wait` tool (plan.md §8.0, §11.1). A settled background run comes back to the session as mail. The test support still names a `wait` call, so a reader learns a wrong surface.

## What

Rewrite these places for the mail model. Write in ASD-STE100 Simplified Technical English.
- `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`: the doc comments that name "the `wait` play" and "a `wait` call that names the run", and the doc comment of `completionTokenField` ("the field a `wait` call names the run to collect under"). Find out if the collecting play is still used. If no test uses it, remove it; if a test uses it, rewrite its doc comment so that it does not name a `wait` tool.
- `Tests/FoundationModelsACPAgentTests/Support/RecordedTranscriptFile.swift`: the doc comment of `completionTokenKey` ("the background run a `wait` collects").

## Acceptance Criteria

- [x] `rg -n "\`wait\`" Tests IntegrationTests` shows no line that tells of a `wait` tool as if it exists.
- [x] `swift test` passes with zero compiler warnings.

Found by ^f4tye31. #generation-queue