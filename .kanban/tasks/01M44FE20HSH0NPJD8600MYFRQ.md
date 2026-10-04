---
assignees:
- claude-code
position_column: todo
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