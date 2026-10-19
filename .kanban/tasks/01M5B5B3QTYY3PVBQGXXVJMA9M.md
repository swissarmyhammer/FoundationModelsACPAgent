---
depends_on:
- 01M5ARV1VSNEZKVWBXC0BXNZPA
position_column: todo
position_ordinal: '80'
title: HookCompositionTests use the public Router test container, not sessionChecked
---
Precondition (other board): the FoundationModelsRouter card 01M5B5B3BVXQHZP8C14FK069KG is done and on origin/main. Until then, this card is blocked. #hooks #blocked-external

## What
`Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift` has a private `HookLayeredLLMContainer`, and it reaches the internal Router symbol `Tool.sessionChecked` through `@testable import FoundationModelsRouter`. The user decided on 2026-10-19 that Router gives a public test container for this. When that Router card is done:
- Update the FoundationModelsRouter pin (`swift package update FoundationModelsRouter`).
- Use the new public container of `FoundationModelsRouterTestSupport` in `HookCompositionTests`.
- Delete `HookLayeredLLMContainer`, and every use of `sessionChecked` in this repository.
- Do not remove `@testable import FoundationModelsRouter` from the test target if other tests still need it; remove only the uses that this helper needed.

## Acceptance Criteria
- [ ] `rg -n "sessionChecked|HookLayeredLLMContainer" Tests Sources` gives no result.
- [ ] Each test of `HookCompositionTests` passes with the public container, and still sees `PreToolUse`, `PreToolResult`, `PostToolUse` and the snapshot checkpoint.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift`: the existing tests, changed to the public container.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd`. Change the tests first, then remove the helper.