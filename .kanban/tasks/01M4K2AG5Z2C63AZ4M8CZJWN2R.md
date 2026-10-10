---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4k2m3n1fhmcvgm86t73cm0k
  text: |-
    Research done.
    - `RoutedACPAgent.init(..., inlineSettleGrace:)` is internal. `makeStubAgent` is in the target FoundationModelsACPAgentTestSupport, which is a library product. It cannot use `@testable import`: `bench/swebench_run.py` runs `swift build -c release`, which builds that library, and a release build has no testable module. Decision: merge the two initializers into one public initializer with `inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace`. The change is additive and source-compatible for each caller.
    - ToolSectionCodecTests holds the same body three times for git, environment and agents in four test families: the no-key default, the off shapes, the unknown body key, and the `config init` round trip. To remove the cause from the whole file, one table of sections drives each of the four families.
    - ConfigShowTests: `keyLines(in:)` is the only mutable state. The new form marks a line as an item line when it opens an item or when one of its ancestor lines opens an item.
  timestamp: 2026-10-10T14:14:12.897580+00:00
- actor: claude-code
  id: 01m4k2ykhctst2j9ezz2ha4jkp
  text: |-
    Implementation landed. Each of the three findings is fixed, and each cause is gone from its file.
    - AgentsToolTests: `makeAgent` is now one `makeStubAgent(...)` call plus `initialize`. `makeStubAgent` takes `inlineSettleGrace: TimeInterval = CatalogContext.defaultInlineSettleGrace` and gives it to `RoutedACPAgent`.
    - Production change, which the finding needs: `RoutedACPAgent` has one public initializer now. Before, a public initializer called an internal one that took `inlineSettleGrace`. Now the public initializer takes `inlineSettleGrace`, and its default is the same value as before. Each caller still compiles with no change. I did not use `@testable import` in the TestSupport library, because `swift build -c release` (bench/swebench_run.py) builds that library, and a release build has no testable module.
    - ConfigShowTests: `keyLines(in:)` has no `var` now. It is `let` arrays built with `map`/`filter`. A new helper, `isAncestor(_:of:indents:)`, tells if a line is inside the block of an earlier `-` line. The result is the same as the result of the old algorithm.
    - ToolSectionCodecTests: the git, environment and agents copies of four test families (no key, off shapes, unknown key, `config init` round trip) are now four tests with parameters over one `switchOnlySections` table. Each table row keeps its own `configInitFragment` and its own unknown key. The off shapes run over a `sections x OffShape.allCases` product. The test `eachOffShapeOfTheAgentsSectionReadsBackTheSame` is only for agents, and it stays the same.
  timestamp: 2026-10-10T14:19:56.844381+00:00
- actor: claude-code
  id: 01m4k2yq2np0wx491k2rx2q4mt
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift, Tests/FoundationModelsACPAgentTests/ConfigShowTests.swift, Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift. `swift test --scratch-path .build/alt --force-resolved-versions --filter 'AgentsToolTests|ConfigShowTests|ToolSectionCodecTests'`: 59 tests in 3 suites passed. Full root `swift test --scratch-path .build/alt --force-resolved-versions` with an empty SKILLS_MARKETPLACE_CACHE: 849 tests in 91 suites passed, 0 failures, no compiler warnings. The 1 known issue is the `withKnownIssue` check that HarnessSmokeTests already had. 3/3 findings are `- [x]`.
    - next: /review
  timestamp: 2026-10-10T14:20:00.469483+00:00
- actor: claude-code
  id: 01m4k3npzfykjme8azqct3zek0
  text: |-
    ### test — green
    - evidence: swift test (scratch .build/alt, empty SKILLS_MARKETPLACE_CACHE) - 849 tests in 91 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests), 0 failures. swift test in IntegrationTests (--no-parallel) - 30 tests in 11 suites passed. swift build -c release (scratch .build/alt-release) - Build complete, the test support library compiled. Warnings: only mlx-swift dependency warnings (C++17 extension, missing creator for Cmlx.bundle). None in this package's files.
    - next: review
  timestamp: 2026-10-10T14:32:34.031698+00:00
position_column: doing
position_ordinal: '80'
title: Fix the code-hygiene findings of the range af04397..0774430 (agents tool and skills marketplace tests)
---
## Why

The reviews of ^c4a6mwy and ^t87yzmg ran without `code-hygiene/dead-code-swift`, because of the orphan checkout in `.build`. On 2026-10-10 a `code-hygiene` review of the whole range `af04397~1..0774430` ran. The dead-code rule found nothing. Three other rules found these items. Each one is a requirement. Fix each cause in the whole file.

## Review Findings (2026-10-10 08:59)

- [x] `Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift:373` `reuse/reuse` — The new `makeAgent(label:inlineSettleGrace:)` rebuilds the stub agent that `makeStubAgent` already builds, then calls `initialize`. The copy repeats the router, the user directory and the defaults-layer environment. It does not extend `makeStubAgent` with an `inlineSettleGrace` parameter, so the test suite now has two stub-agent constructors that drift apart. The `makeStubAgent` doc comment says every suite constructs through it. Add an `inlineSettleGrace: TimeInterval` parameter, with the current default, to `makeStubAgent` in StubProfileFixtures.swift and pass it through to `RoutedACPAgent`. Then replace the body of `AgentsToolTests.makeAgent` with one `makeStubAgent(...)` call plus `initialize`.
- [x] `Tests/FoundationModelsACPAgentTests/ConfigShowTests.swift:89` `swift/immutability` — The `keyLines(in:)` helper keeps a mutable `var itemIndent` that the `filter` closure reads and writes on every line. The reader must walk the whole closure to learn which lines are kept, and the filter depends on the order of the calls. A `map`/`filter` over a precomputed set of item ranges would state the result without shared mutable state. Compute the sequence-item lines in one pass that returns a Boolean per line, or split the text into item blocks first, then take the key lines from the blocks that are not items. Keep the result as a `let` built from `map`/`filter`.
- [x] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift:384` `reuse/reuse` — The new test `theConfigInitDocumentReadsBackWithTheAgentsToolOn` repeats the body of the existing environment round-trip test. Both build the builtin configuration, write it with `ConfigurationYAML.documentText`, read it back with `loadProjectConfig`, and assert the text fragment, equality with the builtin, and the mounted options. Only the section name and the expected fragment differ. Writing a second copy means the two round-trip checks can drift apart. Extend the existing round-trip check into one parameterized test over the section, for example by passing the section key and a closure that reads its `mountedOptions`, and use it for both `environment` and `agents`. Keep the per-section fragment as an argument so each case still names its own key.

## Tests

The suites AgentsToolTests, ConfigShowTests, ToolSectionCodecTests and each suite that uses `makeStubAgent` pass. The full root suite passes. These are refactors of tests that already pass, so each test must still pass after the change.

#tests