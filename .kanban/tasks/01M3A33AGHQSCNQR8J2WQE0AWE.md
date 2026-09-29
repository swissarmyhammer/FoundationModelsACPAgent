---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3q9wvng90xtjp5xxkyv84my
  text: |-
    Research (implement step).
    - The Router model on the card is obsolete. The current Router (.build/checkouts/FoundationModelsRouter) has no request/attempt API. It has one generation queue for each resident model. The queue unit is a submission (`SessionEvent.submissionQueued/Started/Ended`, `SubmissionEnd{usage, finishReason}`). A generation call (`SessionEvent.generationCall`) is one model call inside a submission. `answered(SessionAnswer)` gives the total of a chain. Cancel is `RoutedSession.cancel() -> CancellationResult` (`.requested` / `.nothingToCancel`); `drain()` waits for the background work; `close()` drains too. There is no `cancelCurrentRequest()` and no `wait` tool.
    - The name rule of this task is therefore: "prompt" = the agent unit; "submission" and "generation call" = the Router units; "turn" only in ACP protocol words.
    - Scope at start: 128 lines in Sources match `\bturns?\b` (many are the verb "turns"), plan.md 62, cli-plan.md 7, README.md 3. Two gate lines in plan.md (§8.2 and §10.1).
    - Log and error texts to change: `with no running turn; ignored` (PromptExecution), `the turn ends with` (PromptExecution), `this request waits for a place in the model queue` (EventProjection), `an action command makes no model turn` (CommandDispatch). `rg` finds no test, bench script, integration test or evaluation test that reads these texts.
    - BuiltinInstructions.swift has four lines with "turn" inside the model instruction string (the text the model reads). A change of that text changes model behavior, so rule 4 (no behavior change) keeps them. They go on the kept list.
  timestamp: 2026-09-29T19:22:35.568429+00:00
- actor: claude-code
  id: 01m3qacyzt1sc2mdxqnyq7k836
  text: |-
    Implementation landed. The prose in Sources/, plan.md, cli-plan.md and README.md now uses prompt / submission / generation call.

    Kept lines of `rg -n -i "\bturns?\b" Sources`. These 4 lines are in the model instruction string (runtime text that the model reads). A change there changes model behavior, so rule 4 (no behavior change) keeps them:
    - Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift:131 `- ACT FIRST. The first thing you do in a turn is a tool call, and`
    - BuiltinInstructions.swift:137 `the turn and changed nothing.`
    - BuiltinInstructions.swift:162 `- Do the work in this turn. Do not describe a plan and then stop.`
    - BuiltinInstructions.swift:188 `of the turn. Code that is not in a file is not a change.`
    The doc comments above that string are rewritten. A later card can rewrite the model text if a person decides that the change is worth an evaluation run.

    Kept lines in plan.md: 908-909, the §8.0 definition of "Turn" (it names `end_turn`, `max_turn_requests` and the spec quote "prompt turn").

    `rg -n -i "model gate|generation gate|generationGate|turn-long" Sources plan.md README.md` gives no result.

    Runtime texts that changed (rg found no reader in Tests, bench, IntegrationTests or EvaluationTests):
    - `... with no running prompt; ignored` (was "running turn")
    - `...; the prompt ends with ...` (was "the turn ends with")
    - `...; this submission waits for a place in the model queue` (was "this request waits")
    - the `.action` attachments reason: `an action command sends nothing to the model, ...` (was "makes no model turn")

    plan.md: the new §8.0 defines prompt, submission, generation call, the model queue, and what holds a model. §7.1, §8.1, §8.2, §8.4, §8.6, §10.1 and §21 refer to it. The serialGate / gate text, the turnStarted/turnEnded rows, the cancelPrompt(id:) row and cancelCurrentTurn() are removed.

    Discovery: the Router doc (RoutedSession.swift) says that an in-band tool body is part of its submission and holds the model. A prompt holds no model only while it waits for a background run (runCode after its inline grace, a shell command, an elicitation inside such a run). §8.0 states this detail.

    New card ^f4tye31: plan.md §4.7, §11, §11.1 and README.md still name the obsolete `wait` tool.
  timestamp: 2026-09-29T19:31:23.258765+00:00
- actor: claude-code
  id: 01m3qad0wef8wmf5jfa76t1stq
  text: |-
    ### implement — changed
    - evidence: `swift test`: 615 tests in 70 suites passed (same count), no compiler warnings (only the SwiftPM "missing creator for mutated node" build-system line). `swift build --build-tests` in IntegrationTests/: Build complete. The diff of Sources changes only comments and the 4 runtime texts. Files: plan.md, cli-plan.md, README.md, and 30 Swift files in Sources/FoundationModelsACPAgent and Sources/acp-agent.
    - next: /review
  timestamp: 2026-09-29T19:31:25.198057+00:00
- actor: claude-code
  id: 01m3qaxzr8x1ssqs5evem2hzqd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c4f8caf). 35 files reviewed. 0 findings, 0 confirmed, 0 refuted (21 attempted, 0 failed). No validator matches plan.md, cli-plan.md and README.md, so the engine did not review these files. The engine ignores the .kanban/ files because of .reviewignore.
    - next: none. The task moved to done.
  timestamp: 2026-09-29T19:40:41.096211+00:00
- actor: claude-code
  id: 01m3qaykpme600jd1sn11vjng1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — plan.md, cli-plan.md, README.md, 30 Swift files in Sources/
    - test: green — swift test 615 tests pass; IntegrationTests build ok
    - commit: c4f8caf
    - review: clean — zero findings; task moved to done
    - checklist: the orchestrator checked the acceptance items. The gate rg gives no result; plan.md §8.0 exists; the turn rg shows only the 4 kept BuiltinInstructions.swift lines (model text, kept by decision).
  timestamp: 2026-09-29T19:41:01.524517+00:00
depends_on:
- 01M3A32XJSSVH8E7XKWGMDF7FR
position_column: done
position_ordinal: f880
title: Rewrite the prose of plan.md, the doc comments and the log text for prompt / submission / generation call and the model queue
---
## Why

After the symbol renames, the prose still says "turn" in many places (for example `EventProjection.swift`, `SessionResume.swift`, `CommandDispatch.swift`). The prose also still describes the old Router lock: one gate for each model, held for the whole turn. A reader of the old text learns a wrong model of the system.

## The current Router model

Router has no turns and no request / attempt / pass API. It has one generation queue for each resident model.
- A **submission** is one queue item: one whole SDK call (`SessionEvent.submissionQueued` / `submissionStarted` / `submissionEnded`, `SubmissionEnd{usage, finishReason}`).
- A **generation call** is one model call inside a submission (`SessionEvent.generationCall`).
- `answered(SessionAnswer)` gives the total of a chain. An overflow retry is two submissions with a compaction between them.
- Cancel is `RoutedSession.cancel() -> CancellationResult` (`.requested` / `.nothingToCancel`). There is no `cancelCurrentRequest()`, no `cancelCurrentTurn()` and no `cancelPrompt(id:)`. `drain() async -> Bool` waits until all background work is complete, and `close()` also drains.
- A settled background run comes back as mail and starts a new answer (a new submission).
- A prompt that waits for a background run (and an elicitation inside it) holds no model. There is no `wait` tool.

## What

1. Apply the name rule to the prose in `Sources/`, `plan.md`, `cli-plan.md`, and `README.md`:
   - **prompt**: the agent unit (one `session/prompt` to its `idle`).
   - **submission** / **generation call**: the Router units, with the Router meaning.
   - "turn" only in ACP protocol words (`end_turn`, `max_turn_requests`, a quote of the ACP spec "prompt turn").
2. Write the queue model in `plan.md`: one short section that defines prompt, submission, generation call, and the per-model queue. Refer to it from §7.1 (the busy refusal stays: one prompt for each session), §8.1, §8.2, §8.4 (the event table rows for the submission events and the usage event for each generation call), §8.6 (the cancel table: `RoutedSession.cancel()` and its result names `.requested` / `.nothingToCancel`), §10.1, and the dependency table. Remove the old gate / turn-long lock description.
3. Update the log text that says "turn" for the agent unit (for example `"session/cancel ... with no running turn; ignored"`, `"the turn ends with"`). Check that no test and no bench script reads the old text: `rg -n "running turn|the turn ends" Tests bench IntegrationTests EvaluationTests`.
4. Do not change code behavior.

## Acceptance Criteria

- [x] `rg -n -i "\bturns?\b" Sources` shows only ACP protocol words, and each remaining line is in a list in a comment on this task. Exception by decision: 4 lines in `BuiltinInstructions.swift` (131, 137, 162, 188) stay. They are text that the model reads, and a change to them is a behavior change.
- [x] `rg -n -i "model gate|generation gate|generationGate|turn-long" Sources plan.md README.md` gives no result.
- [x] `plan.md` has one short section that defines prompt, submission, generation call, and the per-model queue, and the other sections refer to it.
- [x] `swift build` and `swift test` pass (615 tests, the same count), with zero compiler warnings; `swift build --build-tests` passes in `IntegrationTests/`.

## Tests

- [x] No behavior change. If a test reads a log or error text that changed, update the test in the same change.
- [x] Run `swift test`. All pass, with the same test count as before.

## Workflow
- Use `/tdd` — for a prose change, the green suite before and after the change is the test. #generation-queue