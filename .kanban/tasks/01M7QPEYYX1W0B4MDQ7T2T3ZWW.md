---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qpfbmnyfq18ksyt0s5c5t3
  text: |-
    Router ROUTER-13 field names are final (2026-11-18, Router task ^h27ffj0, not on origin/main yet; the Router sends the sha when it lands):
    - `ProfileFitEstimate.contextTokens: Int?`: the window of the chosen fit; nil when the profile does not fit.
    - `ProfileFitEstimate.defaultMinimumContextTokens = 32_768` (public static).
    - `Router.estimateFit(of:minimumContextTokens:)`, with that default. `estimateFit(of:)` still compiles.
    - A largest fitting window under the minimum gives `fits == false`, `contextTokens == nil`, and a `failure` that names both windows. When the native window is under the minimum, the minimum is the native window.
    - `resolve(profile:)` does not change.
    Write the stub fit source with these names.
  timestamp: 2026-11-18T16:05:11.957798+00:00
- actor: claude-code
  id: 01m7qss1vssrjg8bp9sdfcw956
  text: |-
    Dependency available (2026-11-18): Router ROUTER-13 (^h27ffj0) is on FoundationModelsRouter origin/main 429156b8. Run `swift package update FoundationModelsRouter` when this task starts (not while another task builds).
    - `ProfileFitEstimate.contextTokens: Int?`: the window of the chosen fit, nil when it does not fit. `requiredBytes` is the charge at that window.
    - `ProfileFitEstimate.defaultMinimumContextTokens = 32_768`.
    - `Router.estimateFit(of:minimumContextTokens:)`, with that default. `estimateFit(of:)` still compiles.
    - A largest fitting window under the minimum gives `fits == false`, `contextTokens == nil`, and the failure "the largest window that fits is X tokens; a profile needs Y". Y is the minimum, or the native window when that is smaller.
    - A profile with an explicit `context` uses that context as its window, and the minimum does not apply. The bundled profiles set no `context`.
    - `resolve(profile:)` does not change.
    - Router check with fixed fixtures: `small` (Qwen3.5-9B 4-bit, MTP, kvBits 8, h2o decision model) fits 16 GB with about 52K tokens. Qwen3.8-27B 4-bit does not fit 16 GB.
    All dependencies in other repositories are now on main; this task waits only for ^56r9vp9 (and ^sc4qx6z for the shared fallback function).
  timestamp: 2026-11-18T17:02:55.353398+00:00
- actor: claude-code
  id: 01m7rghwgqm4njs9b06s35mb1k
  text: |-
    ### review — findings
    - evidence: review sha bdf13fe~1..bdf13fe; findings 5, confirmed 5, refuted 4, attempted 28, failed 0. Sources/FoundationModelsACPAgent/ComposedAgent.swift:436 (duplication/duplication), Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift:535 (duplication/duplication), Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:129 (swift/preconditions), Tests/FoundationModelsACPAgentTests/ModelsGraphTests.swift:376 (reuse/reuse), Tests/FoundationModelsACPAgentTests/Support/ProfileFitStub.swift:27 (code-hygiene/idioms-swift). No validator matched ARCHITECTURE.md and README.md, and the engine did not review them.
    - next: correct the 5 findings in the section "Review Findings (2026-11-18 17:35)". The task stays in review.
  timestamp: 2026-11-18T23:40:57.751478+00:00
- actor: claude-code
  id: 01m7rhgperwfa7wp3gjwyy391a
  text: |-
    Review fix (2026-11-18):
    - `ComposedAgent.makeRouter` now has defaults (`nil`) for the chunk gate, the recordings root and the hooks. `makeProfileFitSource` calls it, so one place builds the router. The live fit router now has a `LiveModelLoader`; a fit read loads no model, thus the loader is not used.
    - `ConfigurationLoader.resolvingProfile`: the name comes first from `profileLayers.names(cwd:)` (unknown name: the warning and the fallback name), then one `read`.
    - `ModelsEngine.fallbackProfile`: fixed in the ^sc4qx6z commit (a356... see that card). It is a throwing function with a log record; `assertionFailure` only for an unknown fallback name (a programmer error), not for a bad user file, because a bad user config must not crash.
    - `ModelsGraphTests.profiles(_:selecting:)` takes the selection set; `windowRows` calls it.
    - `ProfileFitStub`: the explicit init is removed; the synthesized init has the same label.
    Tests: ModelsGraphTests, ConfigurationLoaderTests, HuggingFaceTokenProviderTests, AgentCompositionTests: 106 passed.
  timestamp: 2026-11-18T23:57:47.352359+00:00
- actor: claude-code
  id: 01m7rhp611c8krewm1davxs11c
  text: |-
    ### implement — changed
    - evidence: 7be4fd8 — Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift, Tests/FoundationModelsACPAgentTests/ModelsGraphTests.swift, Tests/FoundationModelsACPAgentTests/Support/ProfileFitStub.swift. The `fallbackProfile` finding is fixed in a357f54 (^sc4qx6z); the earlier comment gave a wrong sha prefix. Full suite: 2372 tests in 249 suites passed, 0 compiler warnings
    - next: review
  timestamp: 2026-11-19T00:00:47.137464+00:00
- actor: claude-code
  id: 01m7rhxm4des6j3b83ffqz2cva
  text: |-
    ### review — clean
    - evidence: review sha 7be4fd8~1..7be4fd8. 4 files reviewed. 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. All 5 prior items are checked.
    - next: The task is in done. No more work is necessary.
  timestamp: 2026-11-19T00:04:50.957023+00:00
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: done
position_ordinal: ffffff8980
title: 'ACPA-23 (D203): the default profile is the largest that fits; contextTokens and target memory on the models endpoint'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, parts 2 and 5.

## Dependencies

- ^56r9vp9 (the three bundled profiles). Also do it after the unknown-name task, because both use the fallback function.
- FoundationModelsRouter ROUTER-13 on `main` (`router-brief.md`): the minimum window (32K) in `estimateFit(of:)`, and `contextTokens` in `ProfileFitEstimate`. Not on this board. You can start with a stub fit source, and connect Router when it is on `main`.

## Current state

- The default name is static: `AgentConfiguration.profile.name = BundledProfiles.defaultName` (`Configuration/AgentConfiguration.swift:302`). No fit decides it.
- The `models` endpoint gives the fit of each profile with `ProfileFitReport` (`Models/ProfileFit.swift:9-46`): `fits`, `requiredBytes`, `budgetBytes` and `failure`, from `Router.estimateFit(of:)` (`:62-68`). The `ModelProfile` GraphQL type is at `Models/ModelsGraph.swift:472-492` and `Models/ModelsGraphTypes.swift:246`. It has no window and no target memory.

## Change

1. When no layer sets `profile`, the agent uses the largest bundled profile, in the order of `BundledProfiles.names`, whose fit estimate says `fits` (the fit includes the minimum window of ROUTER-13). When no fit can be read (no Metal device, the estimate fails or is cancelled), the agent uses `small`. The fallback of an unknown name is the same choice.
2. The fit read is async and `resolvingProfile` is sync. Do the choice where the async load is (`SessionSetup.load`, or the settings store). Keep one function that both the agent and the `acp-agent` CLI call.
3. `ProfileFitReport` and the `ModelProfile` type get `contextTokens: Int` (nullable): the window of the fit, from `ProfileFitEstimate.contextTokens`.
4. `ModelProfile` gets the target memory of a bundled profile (for example `targetMemory: String`: "48 GB or more", "32 GB", "16 GB or 24 GB"). It is `null` for a profile file of the user or the project.
5. README: describe the default by fit.
6. When the field names are on `main`, tell the TestudoApp session (testudoapp-9a) the names.

## Tests

- With a stub fit source where only `small` fits, no `profile` key selects `small`.
- Where `medium` and `small` fit, it selects `medium`.
- Where the source fails, it selects `small`.
- The CLI uses the same choice.
- The endpoint gives `contextTokens` and the target memory of each bundled profile, and `null` target memory for a user profile file.

When this lands, push to origin/main and send the sha and the field names to the TestudoApp session (testudoapp-9a). #d203 #profiles #acpa-23

## Review Findings (2026-11-18 17:35)

> Scope: `review sha bdf13fe~1..bdf13fe` — reviewed the diffs only — lines this change added or modified. 25 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/ComposedAgent.swift:436` `duplication/duplication` — `makeProfileFitSource(for:home:huggingFaceTokenProvider:)` repeats the live branch of `makeRouter(...)`: the same `switch modelSource` with a `.live` arm that builds `Router(cacheDir: home.routerCacheDirectory, ... metadataSource: HuggingFaceMetadataSource(tokenProvider: huggingFaceTokenProvider))` and a `.stub` arm that calls `EchoModel.makeRouter(cacheDirectory: try makeStubCacheDirectory())`. The same construction is spelled twice, so a change to the router's cache directory or metadata source has to be made in both places. Extract the router-building switch into one helper that takes the optional recording, loader and hook arguments, with defaults. `makeProfileFitSource` then calls it with only the cache and metadata arguments. Or extract the shared `Router(cacheDir:metadataSource:)` construction into a helper that both functions call.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift:535` `duplication/duplication` — Inside `resolvingProfile(of:in:warnings:)`, the `catch` arm repeats the `try` arm's assignment `resolved.profile.resolved = try profileLayers.read(..., cwd: workingDirectory)`. The two copies differ only in the profile name argument (`resolved.profile.name` versus `fallbackProfileName`). Both copies are `+` lines of this change, so a later change to how the profile file is read or assigned must be made twice. Compute the name to read first, then make a single read. For example, catch `ProfileStoreError.unknownProfile` to set `name = fallbackProfileName` and append the warning, then perform one `resolved.profile.resolved = try profileLayers.read(name, cwd: workingDirectory)` after the do/catch.
- [x] `Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:129` `swift/preconditions` — The `fallbackProfile` property hides a failed profile read. `try?` discards the error, and `?? BundledProfiles.defaultProfile` returns a profile with no log record and no assertion. A reader cannot tell that the configured fallback failed to load, so the defect stays hidden. Use a `do`/`catch` that calls `assertionFailure` and writes a production log record with the profile name and the error, then returns `BundledProfiles.defaultProfile`. Keep the fallback value, and record the failure.
- [x] `Tests/FoundationModelsACPAgentTests/ModelsGraphTests.swift:376` `reuse/reuse` — `windowRows` repeats the body of the existing `profiles` helper (run the GraphQL document, `#expect` no codes, `#require` the `profiles` array), differing only in the selection set and in keying the rows by name. A near-match that was not extended, so the query-and-parse logic now exists twice and can diverge. Parameterize the existing helper with the selection string, for example `static func profileRows(_ graph: ModelsGraph, selecting fields: String = "...") async throws -> [[String: Any]]`, so `profiles` and `windowRows` both call it. `windowRows` then only maps the returned rows by name.
- [x] `Tests/FoundationModelsACPAgentTests/Support/ProfileFitStub.swift:27` `code-hygiene/idioms-swift` — UseSynthesizedInitializer: remove this explicit initializer, which is identical to the compiler-synthesized initializer.