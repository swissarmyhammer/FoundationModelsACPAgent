---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tmfp1znfby68nx6anwt3kb
  text: |-
    Research is done.
    - Defect 1 cause: `ProfileConfiguration.init(from:)` decodes the old map form with no `preset` to `name = BundledProfiles.defaultName` ("large"). `ConfigurationLoader.resolvingProfile` uses the fallback only when `root.value(at: profile) == nil`. The map is present, so the loader keeps "large" and does not use the fallback. `SettingsStore` runs the same steps (`loadedConfiguration`). `ModelsEngine.selectedProfile()` has the same defect: it decodes the map and reads "large". `profile: null` has the same defect too (decodeIfPresent gives nil, the default name "large" stays, and the key is present).
    - Budget: `Router.estimateFit` and `Router.resolve` both read `hostBudget()` of the same probe. `ComposedAgent.compose` gives `profileFitSource ?? router` to `fallbackName(using:)`, the same router as the resolution. So the budgets agree on the agent path; the cause is the decode, not the budget.
    - Defect 2: the trap "Error raised at top level" is in the client repository: `LiveAgentServer.main() async throws` (`@main`) in FoundationModelsACPClient/IntegrationTests/LiveAgentServer. It builds `RoutedACPAgent` itself and lets the thrown `ProfileResolutionError` escape `main`. In this repository, `AcpAgentCommand.launch(modelChoice:)` catches each error and exits by `exitAfterFailure` (stderr, code 1). The only resolution is in `RoutedACPAgent.init`, before the wire opens; `session/new` resolves no profile.
  timestamp: 2026-11-19T19:28:08.767962+00:00
- actor: claude-code
  id: 01m7tpn0hhxgsqk2x3x1gkhqg3
  text: |-
    Implementation is done (no commit).
    - Cause of "large": `ProfileConfiguration.init(from:)` decodes the old map form with no `preset` (and `profile: ~`) to the in-code default `large`, and `ConfigurationLoader.resolvingProfile` used the fallback only when the `profile` key was absent. The budget was not the cause: `Router.estimateFit` and `Router.resolve` read the same `hostBudget()`, and `ComposedAgent.compose` gives the same router to `fallbackName(using:)`.
    - Fix: new `ProfileConfiguration.name(of:)` (the string, or the `preset` string; else nil). `ConfigurationLoader.resolvingProfile` (and thus `SettingsStore`) and `ModelsEngine.selectedProfile()` use the fallback when the value gives no name.
    - Tests: `OldProfileMapFallbackTests` (loader name, definition, retired-key warnings, null value, composition with a fit stub where only small fits gives small), `ModelsGraphTests.theOldMapFormWithNoPresetSelectsTheFallback`, `FitFallbackBudgetTests` (a router on the 26,800,603,136-byte budget where large does not fit chooses a smaller profile, and the same router resolves it), `ExitCodeTests.aProfileThatDoesNotResolveExitsErrorWithItsReason`. `ConfigurationLoaderTests.theOtherKeysOfTheOldMapFormGiveWarnings` asserted the old wrong value (`large`); it now asserts the fallback.
    - RED: the six defect-1 tests failed before the fix. The budget tests and the CLI exit test passed at the first run: that behavior was already correct, and they stay as guards.
    - Defect 2: the trap is in the client repository (`LiveAgentServer.main() async throws`, `@main`). `acp-agent` already catches each error in `AcpAgentCommand.launch` and exits 1 with the reason on stderr; the new CLI test proves it. `session/new` resolves no profile in this agent (the one resolution is in `RoutedACPAgent.init`, before the wire), thus no refusal path was added. A card for the client `@main` was sent to the FoundationModelsACPClient board.
    - Full suite: 2646 tests, 1 failure: `SessionCancelStopsAllWorkTests.aShutdownStopsTheBackgroundChildRunAndCommandAtOnce` hit its 60 s time limit under load; the suite passed alone in 0.5 s. Not related to this change.
  timestamp: 2026-11-19T20:06:00.497459+00:00
- actor: claude-code
  id: 01m7tpn4rh8j9v50663bhmgr8g
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift, Configuration/ConfigurationLoader.swift, Models/ModelsEngine.swift; Tests: OldProfileMapFallbackTests.swift (new), FitFallbackBudgetTests.swift (new), ExitCodeTests.swift, ModelsGraphTests.swift, ConfigurationLoaderTests.swift
    - next: review

    ### test — red
    - evidence: `timeout 1800 swift test --skip-build`: 2646 tests, 1 failure (SessionCancelStopsAllWorkTests.aShutdownStopsTheBackgroundChildRunAndCommandAtOnce, 60 s time limit under load; the suite passed alone, 7/7). Build: "Build complete!", 0 compiler warnings (1 build-system line "missing creator for mutated node").
    - next: run the full suite again when the machine has no other build.
  timestamp: 2026-11-19T20:06:04.817073+00:00
position_column: doing
position_ordinal: '8180'
title: 'D203: an old profile map with no preset takes the default by fit, and a profile that does not resolve is a reported error, not a fatal error'
---
Bug report from the FoundationModelsACPClient session (2026-11-19), CI run 44584505762, test `aConnectionModelRunsOneTurnAgainstARealAgent`. Log: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/1f1ff490-1f6d-403e-a4b8-a170cd97b235/scratchpad/integ-ci-3.log lines 1544-1560.

## What happened

The client's LiveAgentServer writes the OLD profile map form `profile: {standard: ..., flash: ...}` (no `preset`). The loader warns that `profile.standard` and `profile.flash` are no longer used and ignores them. Then the agent resolved profile "large" on a runner with a budget of 26,800,603,136 bytes (about 26.8 GB). `large` (Qwen3.8 27B 8-bit, 29.95 GB at one token) cannot fit. The process stopped with:
`Swift/ErrorType.swift:254: Fatal error: Error raised at top level: profile "large" did not resolve: ResolutionFailure: profile "large" cannot co-fit a budget of 26800603136 bytes.`
The client saw only `.closed`.

## Two defects to check

1. **The default by fit (^t2t3zww) was not used.** With no usable `profile` name, the default must be the largest bundled profile that fits (here `medium` or `small`), and `small` when no fit can be read. Find which path gave "large": for example, the old map form with no `preset` may map to `BundledProfiles.baseName`/`defaultName` ("large") and not to `fallbackName(using:)`; or the CLI path (`acp-agent`) may not compute the fit fallback; or the fit source used a different budget than the resolution. Fix the path so the old map form with no preset and any other "no usable name" case use the fit fallback, with the SAME budget as `Router.resolve(profile:)`.
2. **A failed resolution is a fatal error.** A top-level `throw` in the `acp-agent` executable traps. The agent must report the error and exit with a clear message and a non-zero exit code (or, for an ACP session, refuse `session/new` with a clear error), not trap. Find where the top-level error escapes (`Sources/acp-agent/...`).

## Tests

- An old map form `profile: {standard: ..., flash: ...}` with no preset, on a fit stub where only `small` fits, resolves `small` (or the largest that fits), with the "no longer used" warnings.
- The fit fallback and the resolution use the same budget (a budget stub that makes `large` not fit gives a fallback that resolves).
- A profile that does not resolve gives a clear error and a non-zero exit (CLI) / a refused `session/new` (agent), not a trap.

When this lands, push to origin/main and send the sha to the FoundationModelsACPClient session (foundationmodelsacpclient-1d). #d203 #profiles #bug