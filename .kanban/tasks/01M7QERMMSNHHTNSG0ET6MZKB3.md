---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Remove the test warnings in MarketplaceRegistryMountTests and AgentSessionLauncherTests
---
Found during ^zx4k6r4 (2026-11-18).

## Status of the first part

The compile error is gone. Commit f98ee74 (^eq7gjw2) adopted Router `main`: `StubModelLoader` and the other loaders take the `kvCache:` argument. On 2026-11-18, main bdc0a7c with Router `main` e089db5, Extras `main` b87233e, Multitool 0201e78d and mlx-swift-lm `stable` 8e3daa7 prints "Build complete!", and 2285 tests pass.

## Current behavior

`swift build --build-tests` prints these warnings in test files:

- `Tests/FoundationModelsACPAgentTests/MarketplaceRegistryMountTests.swift:71`, `:87`, `:199`, `:232`: `result of call to 'add' is unused`.
- `Tests/FoundationModelsACPAgentTests/MarketplaceRegistryMountTests.swift:197`, `:228`: `no calls to throwing functions occur within 'try' expression`.
- `Tests/FoundationModelsACPAgentTests/AgentSessionLauncherTests.swift:48`, `:52`: `no 'async' operations occur within 'await' expression`.

The cause is probably an API change in a dependency (for example, `add` now returns a value and does not throw). Find the cause before you change the tests.

## Change

- Remove each warning above. Do not hide a warning with `_ =` when the test must check the result: check the result.
- Do not change the meaning of the tests.

## Tests

- `swift build --build-tests` prints "Build complete!" with zero warnings in this package.
- The unit suite passes.