---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m44ftxjz5f9qqj143whqzg6f
  text: |-
    Picked up. Research:
    - The registry builds that start a CodeContext and never stop it: ToolCatalogTests.makeContext (default AgentConfiguration), TerminalStreamTests.makeBuiltRegistry and the disabled half of theCatalogBuildsTheStreamOnlyWhenShellIsEnabled, SandboxCompositionTests.makeRegistry, MultiRootConfinementTests.aShellCommandWritesIntoTheAdditionalRoot, MCPCompositionTests.makeContext, TierTwoTests.theCatalogComposesTheSurfaceFromTheLoadedConfiguration. SkillsLibraryTests already sets codeContext = .disabled.
    - Baseline full parallel `swift test` on this machine: 739 tests, 83 suites, 8.866 s. The tests of the card took 2.2 s to 4.1 s; the slowest test was aSessionInAnElicitationHoldsNoModel at 8.857 s.
    - Plan for ToolCatalogTests: makeContext turns the code context off by default; the tests that assert the default registry (aDefault...) and the code context tests keep the default section and call codeContextStop.
  timestamp: 2026-10-04T22:16:31.071468+00:00
- actor: claude-code
  id: 01m44gcnyb66gwebpfz5cf13q5
  text: |-
    Implementation landed (tests only, no production code changed).
    - ToolCatalogTests.makeContext has a new parameter `keepsCodeContext: Bool = false`. The default turns `codeContext:` off before `configure` runs. Five tests keep the default section and stop it with `codeContextStop`: aDefaultContextMountsTheFourSessionTools (through `surface.codeContextStop`), aDefaultRegistrySurfacesTheFilesAndShellNouns, aDefaultRegistryMountsTheCodeContextGroup, theCatalogDoesNotWaitForTheCodeContextIndex, aDefaultRegistryMountsTheWebVerbs. semanticSearchOffCallsNoEmbedder turns the section on through `configure` and stops it.
    - TerminalStreamTests (helper and the disabled half), SandboxCompositionTests.makeRegistry, MultiRootConfinementTests.aShellCommandWritesIntoTheAdditionalRoot, MCPCompositionTests.makeContext: `configuration.tools.codeContext = .disabled`.
    - TierTwoTests.theCatalogComposesTheSurfaceFromTheLoadedConfiguration: the project config YAML now holds `codeContext: false`, so the proof still composes from the loaded configuration.
    Measurement: the full parallel run did not get faster on this machine (8.866 s before, 8.868 s after). The tests of the card take 2.4 s to 4.1 s after the change. The run time comes from other tests (aSessionInAnElicitationHoldsNoModel 8.8 s).
    Discovery: the first `swift test --no-parallel` run stopped on SIGPIPE (signal 13) in ProgressReporterTests.theReporterReadsTheProgressOnTheMainActor. That test does not build a registry. The second serial run was green. Recorded as ^xj2arek.
  timestamp: 2026-10-04T22:26:13.067589+00:00
- actor: claude-code
  id: 01m44gcs6pfqe0tv62h8e97fff
  text: |-
    ### implement — changed
    - evidence: 6 files — Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift, TerminalStreamTests.swift, SandboxCompositionTests.swift, MultiRootConfinementTests.swift, MCPCompositionTests.swift, Integration/TierTwoTests.swift. `swift build -c release` complete, 0 warnings from this package. Parallel `swift test`: 739 tests in 83 suites passed after 8.868 s (1 known issue, as before); slowest aSessionInAnElicitationHoldsNoModel 8.766 s, threePageWalkSeesEverySessionOnceAcrossTwoProjects 4.956 s, closeEndsAMailStartedAnswerThatWaitsForTheModelQueue 4.511 s, noBuiltinInvokesTheModelBackend 4.510 s. `swift test --no-parallel`: first run SIGPIPE in ProgressReporterTests (filed ^xj2arek), second run 739 tests passed after 53.786 s. `swift build --package-path IntegrationTests --build-tests` complete.
    - next: /review
  timestamp: 2026-10-04T22:26:16.406223+00:00
position_column: doing
position_ordinal: '80'
title: Direct ToolCatalog unit tests start a code context they do not need, and never stop it
---
## Why

Found during ^vjaka1g. Each `ToolCatalog.makeRegistry(context:)` or `ToolCatalog.sessionSurface(context:)` call over a default `AgentConfiguration` starts a `CodeContext`: an FSEvents stream, an index store in the working directory, and an index loop that wakes each 300 ms. fseventsd registers the FSEvents streams of the whole machine one at a time, so each start waits behind every other start of the run.

These test helpers build the registry with the code context on, do not test the code context, and never call `codeContextStop`. Thus each started context runs until the test process ends:

- `TerminalStreamTests.makeBuiltRegistry(workingDirectory:)` and `theCatalogBuildsTheStreamOnlyWhenShellIsEnabled()`
- `SandboxCompositionTests` (the registry helper)
- `MultiRootConfinementTests` (the registry helper)
- `MCPCompositionTests` (the `makeRegistry` call)
- `TierTwoTests` (the `makeRegistry` call over the loaded configuration)
- `ToolCatalogTests`: the tests that build a default registry and do not test the code context group

In the full parallel run after ^vjaka1g these tests are the slowest (9 s to 12 s; the run takes 11.8 s).

## What to do

- In each helper that does not test the code context, set `configuration.tools.codeContext = .disabled`.
- In each test that must build a default registry, call `codeContextStop` at the end of the test.
- Keep the code context on only in the tests that test it (`ToolCatalogTests` "The code context group" section).

## Acceptance

- No unit test leaves a started `CodeContext` after it ends.
- Full parallel `swift test` green.