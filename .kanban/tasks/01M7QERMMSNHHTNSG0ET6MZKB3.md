---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qg9ydg11d2b975ve6fn58s
  text: |-
    Causes found:
    - Extras `MarketplaceRegistry.add(_:)` returns `MarketplaceEntry`. It has no `@discardableResult`. Thus the 4 `add` calls gave "result of call to 'add' is unused".
    - Extras `InMemoryMarketplaceSourceStorage` is an actor. Its `loadSources()` does not throw on the concrete type. The two closures called it with `try`. The closure type stays `async throws`, thus removal of `try` does not change the closure contract.
    - `ConnectionTable` in this package is a `final class` with a `Mutex`. Its `owner(of:)` is synchronous. Thus `await` on it gave a warning.

    Changes:
    - MarketplaceRegistryMountTests: each `add` result goes into `added`, and the test checks `added.source` against the added source. The `try` keyword is removed in the two `loadSources()` closures.
    - AgentSessionLauncherTests: the `await` keyword is removed on the two `owner(of:)` calls.

    Note: the build also prints "warning: missing creator for mutated node" for the mlx-swift_Cmlx.bundle. That is a SwiftPM build graph message about a dependency bundle, not a diagnostic in a source file of this package.
  timestamp: 2026-11-18T14:17:23.120266+00:00
- actor: claude-code
  id: 01m7qga0n9m5224etnwjysbvqx
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTests/MarketplaceRegistryMountTests.swift, Tests/FoundationModelsACPAgentTests/AgentSessionLauncherTests.swift
    - next: review

    ### test — green
    - evidence: `swift build --build-tests` prints "Build complete!" with 0 source warnings (1 SwiftPM "missing creator for mutated node" message on the mlx-swift_Cmlx.bundle). `swift test --skip-build`: 2290 tests in 243 suites pass, 0 failures, 1 expected known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps uses withKnownIssue).
    - next: review
  timestamp: 2026-11-18T14:17:25.417679+00:00
- actor: claude-code
  id: 01m7qgggsfyn7se74wxf77c8yx
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (197c47b). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. The engine reviewed 2 files. The ignore rule (.reviewignore) excluded 2 .kanban files.
    - next: The task is in done. No more work is necessary.
  timestamp: 2026-11-18T14:20:58.543719+00:00
- actor: claude-code
  id: 01m7qggx364c0pnshxrfsfe0bb
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — MarketplaceRegistryMountTests.swift, AgentSessionLauncherTests.swift
    - test: green — swift test --skip-build, 2290 tests in 243 suites passed; 0 compiler warnings
    - commit: 197c47b
    - review: clean — 0 findings
  timestamp: 2026-11-18T14:21:11.142673+00:00
position_column: done
position_ordinal: ffffff80
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