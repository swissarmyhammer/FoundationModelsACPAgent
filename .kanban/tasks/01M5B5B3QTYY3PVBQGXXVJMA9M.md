---
comments:
- actor: wballard
  id: 01m5b6cf1fwfxvtd4c8tz7xwjm
  text: 'Precondition met (checked with git ls-remote, 2026-10-19): Router origin/main aeb29e2 has card 01M5B5B3BVXQHZP8C14FK069KG done. API: `HookLayeredLLMContainer(wrapping: ScriptedLLMContainer(script:))` from FoundationModelsRouterTestSupport, with plain imports only. It puts the layers on the tools of each session and each fork through the same path as LiveModelLoader. Do NOT wrap a live container: its backend already adds the layers, so each event would come two times. The public type has the same name as the private HookLayeredLLMContainer in HookCompositionTests: delete the private one, or the name is ambiguous.'
  timestamp: 2026-10-19T23:01:43.087319+00:00
- actor: claude-code
  id: 01m5b6mcbe8qaxzx1f858vr7f5
  text: |-
    Research:
    - The Router pin is now aeb29e2 (`swift package update FoundationModelsRouter`).
    - The unit test target does not link `FoundationModelsRouterTestSupport`. Package.swift must add that product to the test target.
    - `ScriptedLLMContainer` and `StubModelLoader` are of this repository (FoundationModelsACPAgentTestSupport and EchoModel.swift), not of Router.
    - A second use of `sessionChecked` is in `Tests/FoundationModelsACPAgentTests/NoOpToolCallTests.swift` (`NoOpSessionFixture.tools`). The card tells to delete every use, thus that fixture also changes to the public container: its loader wraps the scripted container, and its tools are the plain tools.
    - Plan: one helper `makeHookLayeredModelLoader(script:)` in `Tests/FoundationModelsACPAgentTests/Support/`, over `makeScriptedModelLoader(script:)`, used by the two suites.
  timestamp: 2026-10-19T23:06:02.478832+00:00
- actor: claude-code
  id: 01m5b6v9m3y508y0nc2km8yzmt
  text: |-
    Implementation landed (TDD).
    - RED: the two suites changed to `makeHookLayeredModelLoader(script:)` and the private `HookLayeredLLMContainer` was deleted. The build failed with `cannot find 'makeHookLayeredModelLoader' in scope`.
    - GREEN: Package.swift adds `routerTestSupportProduct` (`FoundationModelsRouterTestSupport`) to the unit test target. The new helper `Tests/FoundationModelsACPAgentTests/Support/HookLayeredModelLoader.swift` wraps the container of `makeScriptedModelLoader(script:)` in the public `HookLayeredLLMContainer(wrapping:)`. 14 tests of the two suites pass.
    - `NoOpToolCallTests`: `NoOpSessionFixture.tools` gives the plain `runCode` now (no `sessionChecked`), and the fixture uses the same loader. Proof that the layer does the work: with the plain `makeScriptedModelLoader`, the two session tests fail (runCount is not 0).
    - `@testable import FoundationModelsRouter` changed to a plain import in `HookCompositionTests.swift` and `NoOpToolCallTests.swift`: they compile without it. The other files keep their `@testable` import.
    - Gap on the first acceptance criterion: `rg -n "sessionChecked|HookLayeredLLMContainer" Tests Sources` still gives 2 lines, both in `Support/HookLayeredModelLoader.swift`. They are the use of the PUBLIC Router type, which has the same name as the deleted private type (the comment of 2026-10-19 tells to use it). `sessionChecked` gives no result. A person must confirm that the criterion means the private type only, or change the criterion.
  timestamp: 2026-10-19T23:09:49.059598+00:00
- actor: claude-code
  id: 01m5b6vcb29rftg0j67xddmk26
  text: |-
    ### implement — changed
    - evidence: `swift test` — 995 tests in 112 suites passed, 0 failures, 0 warnings (1 known issue: the deliberate `withKnownIssue` in HarnessSmokeTests, from before this change). Files: Package.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift, Tests/FoundationModelsACPAgentTests/NoOpToolCallTests.swift, Tests/FoundationModelsACPAgentTests/Support/HookLayeredModelLoader.swift (new). Router pin aeb29e2 in Package.resolved (gitignored).
    - next: /review. A person confirms the first acceptance criterion (the rg finds the public Router type name only).
  timestamp: 2026-10-19T23:09:51.842858+00:00
depends_on:
- 01M5ARV1VSNEZKVWBXC0BXNZPA
position_column: doing
position_ordinal: '80'
title: HookCompositionTests use the public Router test container, not sessionChecked
---
Precondition (other board): the FoundationModelsRouter card 01M5B5B3BVXQHZP8C14FK069KG is done and on origin/main. Until then, this card is blocked. #hooks

## What
`Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift` has a private `HookLayeredLLMContainer`, and it reaches the internal Router symbol `Tool.sessionChecked` through `@testable import FoundationModelsRouter`. The user decided on 2026-10-19 that Router gives a public test container for this. When that Router card is done:
- Update the FoundationModelsRouter pin (`swift package update FoundationModelsRouter`).
- Use the new public container of `FoundationModelsRouterTestSupport` in `HookCompositionTests`.
- Delete `HookLayeredLLMContainer`, and every use of `sessionChecked` in this repository.
- Do not remove `@testable import FoundationModelsRouter` from the test target if other tests still need it; remove only the uses that this helper needed.

## Acceptance Criteria
- [x] `rg -n "sessionChecked" Tests Sources` gives no result, and `rg -n "(struct|class|enum) HookLayeredLLMContainer" Tests Sources` gives no result: no private copy of the container stays in this repository. The only `HookLayeredLLMContainer` in this repository is the use of the public Router type. (Criterion corrected on 2026-10-19 by the planner: the first wording did not know that the public Router type has the same name.)
- [x] Each test of `HookCompositionTests` passes with the public container, and still sees `PreToolUse`, `PreToolResult`, `PostToolUse` and the snapshot checkpoint.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift`: the existing tests, changed to the public container.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd`. Change the tests first, then remove the helper.