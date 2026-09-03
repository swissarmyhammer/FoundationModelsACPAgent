---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1m1mgbfxntz6dwgjhty7m9h
  text: |
    ### design decision — Shape 2, not the card's Shape 1

    The card asks for Shape 1: remove the two environment gates, and select the three slow suites with `test-skip` and `integration-filter`. A plain `swift test` at the root must stay fast. I measured the three candidate mechanisms before I wrote any code.

    **Baseline, before any change:** `swift test` at the root = 361 tests in 39 suites, 1 known issue, **4.96 s** wall clock (test run 1.80 s).

    **(a) A second test target in the same package — measured, does not work.**
    I built a small package with two test targets and ran a plain `swift test`. Both targets ran; the second target printed its marker. So a second test target does not keep the root run fast, and Shape 1 alone leaves the three slow suites in the default run.

    **(b) Honest capability gates — measured, does not work on a capable host.**
    The tier-3 suites load `mlx-community/SmolLM-135M-Instruct-4bit`. The tier-4 eval pins `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`. Both snapshots are already in this host's Hugging Face cache. An honest gate on "the host has the model" therefore OPENS here, and a plain `swift test` would spawn `acp-agent` and drive the eval. The eval's own time limit computes to about 510 minutes. So (b) turns a 4.96 s command into a run of hours. It fails the acceptance gate.

    **(c) A nested `IntegrationTests` package — measured, works.**
    A root `swift test` does NOT run a nested package's tests, and a nested test target CAN `@testable import` the root library through a `path:` dependency. I proved both in the same scratch package.

    **Decision: Shape 2.** It is the only mechanism that keeps the root run fast while removing every environment-variable selector. Seven siblings already use it.

    ### What Shape 2 costs here, and how each cost is paid

    The card's sketch assumes the three suites move with "their support files". They do not stand alone. They use the unit test target's shared support: `AgentClientHarness`, `UpdateCollector`, `makeResolvedDirectory`, `BuiltProductLocator`, `textOnDisk`, `makeStubAgent`, `makeScriptedModelLoader`, `ScriptedTurnStep`, and `ScriptedTurnFixture.makePromptRequest`. A nested package cannot reach a test target of the root package.

    So the shared support becomes a library product, in the family pattern of `FoundationModelsRouterTestSupport`: Router declares `.target(name: "FoundationModelsRouterTestSupport", path: "Tests/FoundationModelsRouterTestSupport")`, makes its declarations `public`, imports `Testing`, and publishes it as a product. This package does the same, as `FoundationModelsACPAgentTestSupport`.

    Two measurements make that cheap:

    - Only `ScriptedTurnFixture.swift` needs `@testable`. I compiled with the attribute removed from it and from `PythonCLISubject.swift`: the only errors were three internal members at one line of `ScriptedTurnFixture`. `PythonCLISubject.swift` needs no `@testable` at all. So `ScriptedTurnFixture` stays in the unit test target, and its `makePromptRequest` factory moves to `AgentClientHarness`, beside the `makeInitializeRequest` factory it already owns.
    - The nested test target declares the root `acp-agent` and `acp-print` executable products. SwiftPM then builds both beside the nested test bundle, where `BuiltProductLocator` looks. Thus `integration-root-products` stays out, as the card asks. `FoundationModelsACP` and `FoundationModelsMultitool` wire their nested packages the same way.

    ### The plan

    1. New library target and product `FoundationModelsACPAgentTestSupport` at `Tests/FoundationModelsACPAgentTestSupport/`, holding `Harness.swift`, `RecordingClient.swift`, `ResolvedTemporaryDirectory.swift`, `ScriptedModel.swift`, `AssertionHelpers.swift`, `BuiltProductLocator.swift` and `StubProfileFixtures.swift`, with `public` declarations.
    2. New `IntegrationTests/Package.swift`, holding `StdioContractTests`, `ClientServerTests`, `TierThreeFixture` and the whole `Evaluations/` directory. `FoundationModelsACP/IntegrationTests` is the precedent for a nested package that holds a live suite beside its own fast suite.
    3. Delete `ACP_TIER3` and `ACP_EVAL` and every `.enabled(if:)` that reads them. Keep `.serialized` and each `.timeLimit`.
    4. `.github/workflows/ci.yml` calls the shared workflow at `@main`.

    ### The YAML changes from the card's sketch

    Shape 2 selects by package, not by suite name, so the two selectors go and `integration-package-path` arrives:

    ```yaml
    jobs:
      ci:
        uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
        with:
          integration-package-path: IntegrationTests
          integration-no-parallel: true
    ```

    `test-skip` and `integration-filter` are no longer correct: after the move, the root package holds none of the three slow suites, so the unit job has nothing to skip, and the integration job runs the nested package whole. `CIWorkflowTests` pins this shape instead of the card's, and it still forbids `integration-gate-env`, `integration-metallib-glob` and `integration-root-products` for the reasons the card gives.
  timestamp: 2026-09-03T16:29:06.287003+00:00
- actor: claude-code
  id: 01m1m2xnhnngybt1xwm1vac9qm
  text: |
    ### implement — changed

    The Shape 2 conversion is in place, and both environment gates are gone.

    **What changed**

    1. `Package.swift` gains the library target and product `FoundationModelsACPAgentTestSupport` at `Tests/FoundationModelsACPAgentTestSupport/`, in Router's pattern. Seven files moved into it and became `public`: `Harness.swift`, `RecordingClient.swift`, `ResolvedTemporaryDirectory.swift`, `ScriptedModel.swift`, `AssertionHelpers.swift`, `BuiltProductLocator.swift`, `StubProfileFixtures.swift`. Only what another module consumes is `public`; `HoldingInstant`, `HoldingClock`, `RecordingClient`, `makeStubRouter`, `StubEmbeddingContainer`, `StubMachine` and `StubMetadata` stay internal, because every caller of each stands inside the module.
    2. `ScriptedTurnFixture.makePromptRequest` moved to `AgentClientHarness`, beside `makeInitializeRequest`. `ScriptedTurnFixture` keeps its `@testable import` and stays in the unit test target. 11 call sites follow the factory.
    3. New `IntegrationTests/Package.swift`, with one test target that holds `StdioContractTests`, `ClientServerTests`, `TierThreeFixture` and the whole `Evaluations/` directory. It declares the root `acp-agent` and `acp-print` products, so SwiftPM builds both beside the nested test bundle and `BuiltProductLocator` finds them.
    4. Every gate is deleted: `ACP_TIER3`, `ACP_EVAL`, the three `.enabled(if:)` traits, and the dataset cap `ACP_EVAL_SAMPLES`. The cap was an environment variable that changed how much of a suite ran, and its name carried the `ACP_EVAL` prefix; `PythonCLIEvaluation` takes `sampleLimit` in code, so a shorter drive is now a smaller number there. `.serialized` and each `.timeLimit` stay.
    5. New `.github/workflows/ci.yml` calls the shared workflow at `@main` with `integration-package-path: IntegrationTests` and `integration-no-parallel: true`, and with no other input.
    6. New `Tests/FoundationModelsACPAgentTests/CIWorkflowTests.swift` (8 cases) and `Tests/FoundationModelsACPAgentTests/Support/PackageRoot.swift`. `PackageRoot` walks up to the directory that holds both `Package.swift` and `Sources`, so the nested manifest cannot be mistaken for the root one. `DocumentationSyncTests` kept its own walk before; the new suite reuses this one instead of copying it.
    7. `plan.md` §17, §20.1, §20.2 and §20.3 no longer say the slow tiers are gated. They name the nested package.

    **TDD**

    `CIWorkflowTests` was written before `.github/workflows/ci.yml` existed. The red run: `Test run with 8 tests in 1 suite failed after 0.037 seconds with 7 issues`. After the workflow file landed, one issue remained, and it was the suite catching this file itself: the doc comment spelled a removed name, and the walk read its own source. The prose no longer spells either name. Green: `Test run with 8 tests in 1 suite passed after 0.038 seconds`.

    **Measurements**

    - Plain `swift test` at the root, warm build, three runs: **5.32 s, 5.09 s, 5.35 s** wall clock, test run 1.78–1.81 s. The baseline before this card was 4.96 s wall clock, test run 1.80 s. The command is as fast as it was.
    - `swift test list` at the root names 34 suites. `StdioContractTests`, `ClientServerTests` and `PythonCLIEvaluationTests` are absent from the root package, so the root run cannot download a model, spawn `acp-agent`, or drive the eval. 349 tests in 34 suites, 1 known issue.
    - The card's selector evidence, with `env | grep -c "^ACP_"` reporting **0**: `swift test --package-path IntegrationTests --filter StdioContractTests` gave `Test run with 1 test in 1 suite passed after 96.445 seconds` (1 m 44.8 s wall clock). The suite runs with no environment variable, it spawns the built `acp-agent`, and it takes 96 seconds — which is why it cannot stand in the root run.
    - The nested package's fast suites: `swift test --package-path IntegrationTests --filter "EvaluatorHonestyTests|PythonCLIDatasetTests|PythonCLISubjectTests"` gave `Test run with 15 tests in 3 suites passed after 0.358 seconds`.
    - `swift test --package-path IntegrationTests --list-tests` names 20 tests in 6 suites, none skipped.

    **Note for the reviewer**

    The org test contract's own `test-partitioning` rule states this shape for Swift word for word: "integration lives in a nested package (e.g. `IntegrationTests/`). The root `swift test` runs unit tests only because the root manifest declares no integration target." The card's Shape 1 sketch could not hold that line here, for the reasons in the design comment above.
  timestamp: 2026-09-03T16:51:35.093223+00:00
- actor: claude-code
  id: 01m1m3p84d8zn4yddpmzn11wnb
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 3 findings, 3 confirmed, 0 refuted; `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:41`, `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:48`, `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift:90` — all `swift/fluent-usage`
    - next: give each single-parameter recording method its argument label, and remove the same cause from the whole of each file.
  timestamp: 2026-09-03T17:05:00.557841+00:00
- actor: claude-code
  id: 01m1m3pkghj6fqt0jskz8kzhn6
  text: |
    ### finish iteration 1 — findings

    - implement: changed. 60 files. The card's Shape 1 gave way to the org contract's Shape 2, with the three measurements recorded in the design comment above.
    - test: green. `swift test` at the root — 349 tests in 34 suites passed, 1 known issue, 0 failures, 0 skipped, 0 build warnings. The one known issue is the intentional `withKnownIssue` in `HarnessSmokeTests`. The nested package: 19 of its 20 tests ran and passed — `StdioContractTests` (1 test, 96.4 s), `ClientServerTests` (3 tests, 96.4 s), and the three fast suites (15 tests, 0.36 s). The twentieth is `PythonCLIEvaluationTests`, the whole-dataset eval; its own time limit computes to about 510 minutes, and the card records that it does not clear its mean floor today. The CI integration job owns that run.
    - **Measured plain `swift test` at the root: 5.32 s, 5.09 s and 5.35 s wall clock over three warm runs (test run 1.78–1.81 s). The baseline before this card was 4.96 s wall clock (test run 1.80 s).** No model download, no `acp-agent` spawn, and no eval: the root package holds none of those three suites, which `swift test list` confirms.
    - commit: changed. `0d09e1b feat(ci): adopt the org CI contract with a nested IntegrationTests package`.
    - review: findings. 3 findings, all `swift/fluent-usage`, all on lines this change wrote:
      - `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:41`
      - `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:48`
      - `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift:90`
    - next: iteration 2 fixes the three findings, and removes the same cause from the whole of each file.
  timestamp: 2026-09-03T17:05:12.209699+00:00
- actor: claude-code
  id: 01m1m42qe8m9fx69abq914rjzk
  text: |
    ### finish iteration 2 — done

    - implement: changed. 4 files. The three `swift/fluent-usage` findings are fixed, and the same cause is removed from the whole of each named file: `UpdateCollector.append(notification:)`, `ElicitationWireRecorder.recordCreate(request:)`, `ElicitationWireRecorder.recordCompletion(notification:)` and `PromptRecorder.record(prompt:)` now label their one parameter. `RecordingClient.sessionUpdate(_:)` and `elicitationComplete(_:)` keep their omitted labels, because the `Client` protocol fixes those signatures. Every call site follows.
    - test: green. `swift test` at the root — 349 tests in 34 suites passed, 1 known issue, 0 failures, 0 skipped. Both packages build with no warning. The nested package's fast suites: 15 tests in 3 suites passed after 0.35 s.
    - **Measured plain `swift test` at the root: 6.71 s, 5.32 s and 5.94 s wall clock over three warm runs (test run 1.81–1.84 s). The baseline before this card was 4.96 s wall clock (test run 1.80 s).**
    - commit: changed. `35d5e0c refactor(test-support): label the recorder parameters of the shared support`. `cli-plan.md` appeared in the working tree during this run from outside this card; it was taken back out of the commit and left untracked.
    - review: clean. `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted, 7 attempted. Every prior finding is checked.
    - next: none. The card is done.
  timestamp: 2026-09-03T17:11:49.448456+00:00
position_column: done
position_ordinal: a580
title: 'Adopt the org CI contract: the shared swift-ci workflow, and suite selectors in place of the environment gates'
---
## What
This package has no CI. No `.github` directory exists. Nothing runs at a commit, although plan.md §20.1 says the tier-2 suite "runs in CI at each commit". Make that sentence true, with the pattern the sibling packages use.

The org test contract is at `/Users/wballard/github/swissarmyhammer/workflows/docs/swift-ci.md`. Read it first. Two rules of it decide this task:

- "`swift test` at the root runs all the unit tests, and only the unit tests."
- "**Do not select the tests with an environment variable.** Select the tests with test filters or with a test package."

This package breaks the second rule twice: `ACP_TIER3` and `ACP_EVAL`. Thus this task is not only a new file. It converts the selection mechanism.

## The pattern to copy
Nine siblings call one reusable workflow:

```
swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
```

It has two jobs, both on `[self-hosted, macOS]`: `Build & test`, then `Integration (opt-in, real dependencies)` with `needs: test`. Every input is optional. The workflow declares no secrets.

There are two accepted shapes. The card sketched Shape 1, from FoundationModelsSkills. **The implementation took Shape 2 instead — a nested `IntegrationTests` package — after measuring that Shape 1 cannot keep a plain root `swift test` fast here.** The design comment on this card records the three measurements. The org contract's own `test-partitioning` rule names Shape 2 for Swift.

## The work
1. **Remove the two environment gates.** Delete `.enabled(if:)` on the gate from each suite, and delete the gate symbols:
   - `Support/TierThreeFixture.swift` — `gateVariable`, `gateOpenValue`, `isGateOpen`.
   - `Evaluations/PythonCLIEvaluation.swift` — `evalGateVariable` and its equivalents.
   - The three suites that carry the gate: `StdioContractTests`, `ClientServerTests`, `PythonCLIEvaluation`.
   Keep `.serialized` and each `.timeLimit`. Keep any gate a suite has on a real capability of the host (a missing model, for example): such a gate reports a skip, and it is not a test selector.
2. **Add `.github/workflows/ci.yml`.** Under Shape 2 the selectors give way to the package path:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
    with:
      integration-package-path: IntegrationTests
      integration-no-parallel: true
```

   Write a header comment that says why each input is there, in the manner of the sibling files.
3. **Add `Tests/FoundationModelsACPAgentTests/CIWorkflowTests.swift`**, modelled on `/Users/wballard/github/swissarmyhammer/FoundationModelsSkills/Tests/FoundationModelsSkillsTests/CIWorkflowTests.swift`. It reads the workflow file and pins: the exact `uses:` line at `@main`; exactly one job, with no `steps:` key; each required input, present once, with the exact value; each forbidden input absent; the four trigger lines; the concurrency group with `cancel-in-progress: true`; and that no file under `Sources`, `Tests`, `IntegrationTests` or `.github` names `ACP_TIER3` or `ACP_EVAL` any more. Read the inputs case-insensitively: GitHub Actions resolves `Integration-Skip:` to the same input as `integration-skip:`. Use this package's own package-root helper; do not copy the Skills symbol name.

## Do not add
- `integration-gate-env` — LEGACY. The shared workflow fails the job when it arrives beside a selector, and it can run only one `.xctest` bundle.
- `integration-metallib-glob` — `MetalLibraryTestBootstrap` already installs the link in-process; Router's header states the same reason.
- `integration-root-products` — the nested test target declares the root `acp-agent` and `acp-print` products, so SwiftPM builds both beside the nested test bundle, where `BuiltProductLocator` looks. **Proven by the 96-second `StdioContractTests` run.**
- `test-filter` and `test-skip` — the root package holds no slow suite any more, so the unit job has nothing to hold out.
- `docc-target`, a `format` job, a `.swift-format` file, caching of any kind. The siblings deliberately have no cache: both jobs open with `rm -rf .build`.

## The silent-green trap
If the gates stay and only the workflow lands, the integration job runs, `.enabled(if:)` skips all three suites, and the job goes green having measured nothing. The composite action's "No matching test cases were run" guard does NOT catch this, because the selector matches — the suites are merely skipped. The gate removal and the workflow are one change for this reason.

## Acceptance Criteria
- [x] `.github/workflows/ci.yml` exists and calls the shared workflow at `@main` with the inputs above and no forbidden input
- [x] No file under `Sources`, `Tests`, `IntegrationTests` or `.github` names `ACP_TIER3` or `ACP_EVAL`
- [x] Plain `swift test` runs the unit tiers and skips nothing of its own; the three slow suites are absent from it because they stand in the nested package, not because of a gate in the code
- [x] `swift test --package-path IntegrationTests --filter StdioContractTests` runs that suite with no environment variable set
- [x] `CIWorkflowTests` fails when the `uses:` line, an input value, a trigger, or the concurrency group changes
- [x] `swift test` → green

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/CIWorkflowTests.swift`
- [x] Run one slow suite by selector alone, with no environment variable, and record the count in the ledger

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-03 11:54)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 65 file(s) reviewed, 12 not reviewed.

- [x] `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:41` `swift/fluent-usage` — Single-parameter method omits argument label without value-preserving conversion. The method `recordCreate` performs a side-effect (recording) rather than converting a value, so the parameter should be labeled for clarity at the call site. Change signature to `public func recordCreate(request: CreateElicitationRequest)` so the call reads as "recordCreate(request: ...)" rather than "recordCreate(...)".
- [x] `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift:48` `swift/fluent-usage` — Single-parameter method omits argument label without value-preserving conversion. The method `recordCompletion` performs a side-effect (recording) rather than converting a value, so the parameter should be labeled for clarity. Change signature to `public func recordCompletion(notification: CompleteElicitationNotification)` so the call reads as "recordCompletion(notification: ...)" rather than "recordCompletion(...)".
- [x] `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift:90` `swift/fluent-usage` — Single-parameter method omits argument label without value-preserving conversion. The method `record` performs a side-effect (recording) rather than converting a value, so the parameter should be labeled for clarity at the call site. Change signature to `public func record(prompt: String)` so the call reads as "record(prompt: ...)" rather than "record(...)".

## Review Findings (2026-09-03 12:07)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed. Zero findings.