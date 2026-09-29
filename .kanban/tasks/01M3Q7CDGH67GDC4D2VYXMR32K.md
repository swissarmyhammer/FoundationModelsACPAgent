---
assignees:
- claude-code
depends_on:
- 01M3A32XJSSVH8E7XKWGMDF7FR
position_column: todo
position_ordinal: '9780'
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

- [ ] `rg -n -i "\bturns?\b" Tests IntegrationTests` shows only ACP protocol words and the verb "turn off".
- [ ] `swift test` passes with the same test count as before, and `swift build --build-tests` in `IntegrationTests/` passes.

## Tests

- [ ] No behavior change. The current suites are the proof. Run `swift test` and `swift build --build-tests` in `IntegrationTests/`.

## Workflow
- Use `/tdd` — for a prose change, the green suite before and after the change is the test. #generation-queue