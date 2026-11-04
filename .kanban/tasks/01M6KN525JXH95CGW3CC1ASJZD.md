---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6knw6cwcvbhe6syjprvght6
  text: |-
    Discovery: the Router TestSupport product is not gone. It still holds StubURLProtocol, RequestRecorder and MetalLibraryTestBootstrap. HookLayeredLLMContainer is the only item that moved to the main target. So Package.swift keeps routerTestSupportProduct (unit target, for the URL stub in HuggingFaceTokenProviderTests) and IntegrationTests/Package.swift keeps the product (MetalLibraryTestBootstrap in EmbeddingModelTests and LiveAgent). Only HookLayeredModelLoader.swift changed its import to FoundationModelsRouter, and the Package.swift comments now name the real use. The agent stub is untouched. Work is on branch wt-router in worktree FoundationModelsACPAgent-wt-router. The kanban tool wrote to the main .kanban, none in the worktree.

    ### implement — changed
    - evidence: commit 4750fac on wt-router; files: Package.swift, Tests/FoundationModelsACPAgentTests/Support/HookLayeredModelLoader.swift. swift build --build-tests ok; full swift test: 1772 tests in 194 suites passed, 1 known issue (HarnessSmokeTests, intentional), zero failures. IntegrationTests (swift package update + swift build --build-tests, built in a copy named FoundationModelsACPAgent because the worktree directory name breaks the ".." package identity) builds.
    - next: /review
  timestamp: 2026-11-04T16:22:04.444996+00:00
- actor: claude-code
  id: 01m6kp0x46mtggfxvbh3jt46zz
  text: |-
    ### review — clean
    - evidence: review sha cbc2e3d~1..cbc2e3d, 2 files reviewed, 7 attempted, 0 failed, 0 findings. swift package update resolved Router main 899e6eb.
    - next: none. Task moved to done.
  timestamp: 2026-11-04T16:24:38.790007+00:00
position_column: done
position_ordinal: ffffad80
title: Use HookLayeredLLMContainer from the main Router target and drop the Router TestSupport dependency
---
## What
Router card ^wn61ts5 is pushed (Router main 899e6ebe). `HookLayeredLLMContainer` is now `public struct HookLayeredLLMContainer: LoadedLLMContainer` with `public init(wrapping: any LoadedLLMContainer)` in the main `FoundationModelsRouter` target. The Router TestSupport file is gone, and `import FoundationModelsRouter` is enough. After the next `swift package update`, the build of this package breaks where it still uses the old TestSupport module.

Files that still use the old names (from a search of the tree):
- `Package.swift` (the `FoundationModelsRouterTestSupport` product dependency)
- `Tests/FoundationModelsACPAgentTests/Support/HookLayeredModelLoader.swift`
- `Tests/FoundationModelsACPAgentTests/HuggingFaceTokenProviderTests.swift`

Note: the session ACPDriver plumbs the same type into `acp-agent-stub` in its own worktree. Do not touch the stub from this task. Check `git log` and `Package.swift` on `origin/main` first, so the two changes do not overlap.

## Do
1. Run `swift package update`, then `swift build --build-tests`, and see the real errors.
2. Replace the TestSupport imports and the product dependency with `import FoundationModelsRouter` (main target). Remove the Router TestSupport dependency from `Package.swift` if nothing else uses it.
3. Keep the tests the same in meaning. Check `IntegrationTests` builds after its own `swift package update` (its pins are gitignored).
4. Do not change a sibling package.

## Acceptance Criteria
- [x] The package builds after `swift package update` with Router main 899e6ebe or newer.
- [x] No source or test file imports `FoundationModelsRouterTestSupport`, and `Package.swift` has no dependency on it (unless another product of it is still needed; then name it in a comment on the task). Exception used: the TestSupport product is still needed for `StubURLProtocol` and `RequestRecorder` (unit target, HuggingFaceTokenProviderTests) and for `MetalLibraryTestBootstrap` (IntegrationTests). See the comment on the task.
- [x] `IntegrationTests` builds.

## Tests
- [x] Run `swift test --filter HuggingFaceTokenProviderTests` and the suites that use `HookLayeredModelLoader`. All pass (covered by the full run).
- [x] Run the full `swift test`. All pass.

## Workflow
- Use `/tdd` where it fits. #router