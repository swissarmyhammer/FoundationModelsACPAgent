---
assignees:
- claude-code
depends_on:
- 01M3A32XJSSVH8E7XKWGMDF7FR
position_column: todo
position_ordinal: '8880'
title: Rewrite the prose of plan.md, the doc comments and the log text for prompt / request / attempt / pass and the model queue
---
## Why

After the symbol renames, the prose still says "turn" in many places (for example `EventProjection.swift` has 97 lines with "turn", `SessionResume.swift` 58, `CommandDispatch.swift` 48). The prose also still describes the old Router lock: one gate for each model, held for the whole turn. A reader of the old text learns a wrong model of the system.

## What

1. Apply the name rule to the prose in `Sources/`, `plan.md`, `cli-plan.md`, and `README.md`:
   - **prompt**: the agent unit (one `session/prompt` to its `idle`).
   - **request / attempt / pass**: the Router units, with the Router meaning.
   - "turn" only in ACP protocol words (`end_turn`, `max_turn_requests`, a quote of the ACP spec "prompt turn").
2. Write the queue model in `plan.md`: one generation queue for each resident model; a pass is one queue item; a prompt that runs a tool, waits for a person, or waits for a background run holds no model. Update §7.1 (the busy refusal stays: one prompt for each session), §8.1, §8.2, §8.4 (the event table rows for the request events and the usage event for each attempt), §8.6 (the cancel table: `cancelCurrentRequest()` and its new result names), and §10.1.
3. Update the log text that says "turn" for the agent unit (for example `"session/cancel ... with no running turn; ignored"`, `"the turn ends with"`). Check that no test and no bench script reads the old text: `rg -n "running turn|the turn ends" Tests bench IntegrationTests EvaluationTests`.
4. Do not change code behavior.

## Acceptance Criteria

- [ ] `rg -n -i "\bturns?\b" Sources` shows only ACP protocol words, and each remaining line is in a list in a comment on this task.
- [ ] `rg -n -i "model gate|generation gate|generationGate|turn-long" Sources plan.md README.md` gives no result.
- [ ] `plan.md` has one short section that defines prompt, request, attempt, pass, and the per-model queue, and the other sections refer to it.
- [ ] `swift build` and `swift test` pass.

## Tests

- [ ] No behavior change. If a test reads a log or error text that changed, update the test in the same change.
- [ ] Run `swift test`. All pass, with the same test count as before.

## Workflow
- Use `/tdd` — for a prose change, the green suite before and after the change is the test. #generation-queue