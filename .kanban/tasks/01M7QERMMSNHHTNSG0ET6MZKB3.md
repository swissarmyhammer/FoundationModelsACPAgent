---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: 'Adopt Router main: StubModelLoader must implement loadLLM(ref:slot:context:kvCache:reporting:)'
---
Found during ^zx4k6r4 (2026-11-18).

## Current behavior

The main tree (HEAD c6a2d28) does not compile against the `main` heads of its dependencies:

- With Router `main` e089db5 and Extras `main` 1c69b4f: `Sources/FoundationModelsACPAgent/Configuration/EchoModel.swift`: `type 'StubModelLoader' does not conform to protocol 'ModelLoader'`. Router 63e4c70c (`feat(profile)!: a profile names its KV cache bits, and the router applies them per profile`) changed the requirement to `loadLLM(ref:slot:context:kvCache:reporting:)`. Extras 1c69b4f (`feat(model-pool)!: the KV cache quantization is part of ModelPoolKey`) is the pair of that change.
- Router `main` also needs mlx-swift-lm `stable` 8e3daa7.
- HEAD c6a2d28 compiles with Router 68930ca0 and Extras ea9ecc6 (pinned by hand in the local, gitignored Package.resolved). With those revisions the build shows these warnings in files that ^zx4k6r4 did not change: `MarketplaceRegistryMountTests.swift` (`result of call to 'add' is unused`, `no calls to throwing functions occur within 'try' expression`) and `AgentSessionLauncherTests.swift` (`no 'async' operations occur within 'await' expression`).

Package.swift uses `main` branch dependencies, thus a clean resolve (CI) gets Router e089db5 and the build fails.

## Change

- `StubModelLoader` (and each other `ModelLoader` of the package) implements `loadLLM(ref:slot:context:kvCache:reporting:)`.
- `ComposedAgent.makeLiveModelLoader` follows the Router 63e4c70c API: the profile gives the KV cache bits, not the loader (check the Router change, then remove `kvCacheQuantization:` from `LiveModelLoader` init if Router removed it).
- Remove the warnings above.

## Tests

- `swift build --build-tests` with Router `main`, Extras `main`, and mlx-swift-lm `stable` prints "Build complete!" with zero warnings.
- The unit suite passes.