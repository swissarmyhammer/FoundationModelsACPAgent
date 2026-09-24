---
assignees:
- claude-code
depends_on:
- 01M3A37J8X6VKD5BKYWSJ4HCZD
position_column: todo
position_ordinal: '8380'
title: Make awaitingUser a plain requires_action wrapper, and prove a waiting session holds no model
---
## Why

The Router task "Delete the permit loan and the human-wait release" (FoundationModelsRouter card `01M39ZP766H4S63AR4R44Y6BA4`) makes `RoutedSession.awaitingUser(_:)` a pass-through: a person wait holds nothing, and a tool wait holds nothing. The API stays, so this agent still compiles. But the text here says the wrong thing:

- `TurnStateOwner.awaitingUser(on:_:)` (`Sources/FoundationModelsACPAgent/Agent/TurnState.swift:121-144`) says it "opens Router's model gate".
- `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift:661-690`: `awaitingUserPairsRequiresActionWithTheRouterGate`.
- `ActiveSession.descendants` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift:93`): "no orphan holds a model gate".
- `ElicitationRelay.swift:24`, `:83`.

Decision in this plan: keep the call to `session.awaitingUser(body)`. It is free, and it keeps the Router contract if the Router gives it a new purpose later. The ACP part (`requires_action`, then `running`) does not change.

## External dependency

Router card `01M39ZP766H4S63AR4R44Y6BA4` on Router `main`.

## What

1. `swift package update FoundationModelsRouter`.
2. Update the doc comments above to the queue model: a wait holds no model; the ACP state still goes `requires_action` → `running`.
3. Rename the test `awaitingUserPairsRequiresActionWithTheRouterGate` to `awaitingUserPairsRequiresActionWithRunning` and remove "gate" from its text.
4. Add the end-to-end proof of the queue benefit at the ACP level.

## Acceptance Criteria

- [ ] Two ACP sessions on one model: A is in an elicitation round trip that the client does not answer. B sends a prompt, and B's prompt completes with `end_turn` while A still waits.
- [ ] Two ACP sessions on one model: A is in a tool body that waits (a scripted tool that waits on a continuation). B's prompt completes while A waits.
- [ ] `rg -n "model gate|Router gate|opens Router" Sources Tests` gives no result.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: `aSessionInAnElicitationHoldsNoModel`, `aSessionInAToolBodyHoldsNoModel`, with a timeout.
- [ ] Run `swift test --filter PromptTurnTests`, then `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue