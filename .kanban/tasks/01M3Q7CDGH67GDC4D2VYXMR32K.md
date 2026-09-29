---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q8eyxvasdchcgnv9458xj2
  text: |-
    Picked up. Research: `rg -c -i "\bturns?\b" Tests IntegrationTests` gives 330 lines in 58 files. Word rule for the rewrite:
    - the agent unit (one session/prompt to its idle) -> "prompt" (or "prompt run" when "prompt" alone can mean the prompt text).
    - one scripted model generation -> "pass"; "model turn" -> "model pass".
    - Router units -> "submission" / "request".
    - Keep: ACP words (end_turn, endTurn, max_turn_requests, the ACP spec quote "prompt turn"), the label "ExitCodeTests-end-turn" (it names the end_turn stop reason), the verb "turn off", and the old Router span name `FoundationModelsRouter.turn` (an identifier that the test quotes).
    - A test prompt text changes only together with each reader of it.
  timestamp: 2026-09-29T18:57:31.579306+00:00
- actor: claude-code
  id: 01m3q8x14ywec1c832n2596tag
  text: |-
    Implementation done. 59 test files changed. The only changes are comments, #expect messages, @Test display names, directory labels and test prompt texts. No identifier and no code path changed.
    - Each changed prompt text changed together with each reader: TierTwoTests "Run the scripted tool pass", ElicitationRelayTests "Run the eliciting tool pass", CancellationTests and SessionLifecycleTests "Run one long prompt", TranscriptFidelityTests "run the snippet, prompt ", TranscriptStoreTests "first prompt"/"second prompt" and its assertion, SandboxCompositionTests `printf prompt > prompt.txt` and its read, IntegrationTests TranscriptRecordingTests "record this prompt" (stub echo, read only through its constant). No Sources file reads any of them.
    - Text sent to a real model in IntegrationTests did not change (ToolCallingTests, SkillTrigger samples, ClientServerTests "say hello" had no "turn").
    - The label "BuiltinCommandsTests-noturn-" is now "BuiltinCommandsTests-no-model-pass-" (the acceptance search does not find "noturn", but it is turn prose).
    - Out of scope, seen: Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift has "a zero-turn session" prose; card ^wqe0awe covers it.
  timestamp: 2026-09-29T19:05:12.606921+00:00
- actor: claude-code
  id: 01m3q8x47cbhyt1m1m4kxxxg3b
  text: |-
    ### implement — changed
    - evidence: 59 files in Tests/ and IntegrationTests/ (57 in Tests/FoundationModelsACPAgentTests and IntegrationTests/Tests, plus Tests/FoundationModelsACPAgentTestSupport/Harness.swift). `swift test`: 615 tests in 70 suites passed (1 known issue, the same deliberate withKnownIssue test as before), zero compiler warnings. `swift build --build-tests` in IntegrationTests/: Build complete. The only other warning is the SwiftPM "missing creator for mutated node" line for the mlx bundle, which is a build-system line and not a compiler warning. `rg -n -i "\bturns?\b" Tests IntegrationTests`: 5 lines, all listed under "Kept matches" in the description.
    - next: /review
  timestamp: 2026-09-29T19:05:15.756554+00:00
depends_on:
- 01M3A32XJSSVH8E7XKWGMDF7FR
position_column: doing
position_ordinal: '8180'
title: Rewrite the "turn" prose of the comments and the test texts in Tests/ and IntegrationTests/
---
## Why

Task ^gmdf7fr renamed the "turn" identifiers of the test support and the test files. The comments and the string literals in `Tests/` and `IntegrationTests/` still say "turn" on 330 lines (measured 2026-09-29 with `rg -c -i "\bturns?\b" Tests IntegrationTests`). Task ^wqe0awe covers only the prose of `Sources/`, `plan.md`, `cli-plan.md` and `README.md`.

## What

1. Apply the name rule to the prose in `Tests/` and `IntegrationTests/`:
   - **prompt**: the agent unit (one `session/prompt` to its `idle`).
   - **pass**: one scripted model generation (one play of a `ScriptedPassStep` script).
   - **request / submission**: the Router units, with the Router meaning.
   - "turn" only in ACP protocol words (`end_turn`, `max_turn_requests`, a quote of the ACP spec "prompt turn") and in the verb "to turn off".
2. Change a test prompt text (for example `"Run the scripted tool turn"`, `"first turn"`) only when no assertion or marker reads the old text, or change the reader in the same change.
3. Do not change code behavior.

## Acceptance Criteria

- [x] `rg -n -i "\bturns?\b" Tests IntegrationTests` shows only ACP protocol words and the verb "turn off".
- [x] `swift test` passes with the same test count as before, and `swift build --build-tests` in `IntegrationTests/` passes.

## Tests

- [x] No behavior change. The current suites are the proof. Run `swift test` and `swift build --build-tests` in `IntegrationTests/`.

## Kept matches of the acceptance search

- `Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift`: the label `"ExitCodeTests-end-turn"`. It names the ACP `end_turn` stop reason of that case.
- `IntegrationTests/.../TelemetryFlushTests.swift`: the span name `FoundationModelsRouter.turn`. It is the literal name that an older Router gives its span, and the test text quotes it.
- `IntegrationTests/.../TelemetryStdoutTests.swift` and `Tests/.../TelemetryBootstrapTests.swift` (two lines): the verb "turn off" ("turns off the whole OpenTelemetry SDK", "turns the export off").

## Workflow
- Use `/tdd` — for a prose change, the green suite before and after the change is the test. #generation-queue