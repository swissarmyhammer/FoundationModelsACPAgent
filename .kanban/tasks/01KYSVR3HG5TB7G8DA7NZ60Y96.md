---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fr68yneh3d4wvr1d1f3vpf
  text: |-
    Research complete. Facts found:
    - Upstream `ProfileDefinition` (../FoundationModelsRouter/Sources/FoundationModelsRouter/Core/ProfileDefinition.swift) agrees with the card: `init(name:description:standard:flash:embedding:context:)`, `context` default 8192, `nil` opts into ladder derivation.
    - `Router.resolve(profile:reporting:)` is public and throws `ResolutionFailure` (internal) or loader errors. `ResolutionProgress` is `@MainActor`; its `init` is isolated, so a nonisolated caller must `await` its construction.
    - `ProfileConfiguration` (Configuration/AgentConfiguration.swift) already holds the layer-1 default coding profile for a 16 GB machine and has no `context` key, per plan §2.4.
    - `LanguageModelProfile` is `Sendable` with `let standard/flash/embedding` handles; `RoutedModel` holds the profile weakly and `makeSession` traps when it is released. `RoutedSession` exposes `nonisolated var profile`.
    - Tests already have `StubProfileFixtures.swift` (StubModelLoader, StubMachine, StubMetadata) and `Support/ScriptedModel.swift`. `AgentClientHarness.makeAgent()` is the one construction path in the tests; three call sites in InitializationTests plus `makeParts()`.
    Plan of work:
    - Add `Configuration/ProfileResolution.swift`: map `ProfileConfiguration` to `ProfileDefinition` (configured name wins, dotfolder name is the fallback, `context: nil`), resolve through `Router.resolve(profile:reporting:)`, catch `any Error`, and wrap it in a readable `ProfileResolutionError`.
    - Replace `RoutedACPAgent.init(name:)` with an async throwing `init(name:router:configuration:reporting:)` that resolves the resident profile at construction and holds it strongly in a `let`.
    - Update the test harness to construct through a stub router; write ProfileResolutionTests first (TDD).
  timestamp: 2026-09-02T00:27:05.045839+00:00
- actor: claude-code
  id: 01m1frsr9q80bcvyaw6t6wtwqq
  text: |-
    Implementation landed with TDD (RED observed as a compile failure that named the missing API, then GREEN):
    - `Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift` — `ProfileResolutionError` (readable message with the profile name), `ProfileConfiguration.definition(fallbackName:)` (configured name wins, dotfolder fallback, `context: nil` for the ladder), and `ProfileConfiguration.resolveResident(fallbackName:router:reporting:)` which calls `Router.resolve(profile:reporting:)` and catches `any Error`.
    - `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift` — the old sync `init(name:)` is replaced by `init(name:router:configuration:reporting:) async throws`, which resolves at construction; the resident profile is a strong `nonisolated let residentProfile`.
    - `Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift` — 8 tests: the mapping matrix (name fallback, configured name, three candidates through the YAML decode with `stringValue` and the `@` separator, description and each slot, `context == nil`), construction over the scripted loader, the readable failure report through `FailingModelLoader`, and two sequential sessions after close, with `session.profile === agent.residentProfile`.
    - `Tests/.../StubProfileFixtures.swift` — new shared `makeStubRouter(cacheDirectory:recordingsDirectory:loader:)`; `makeStubProfile` now uses it, so router construction is not copied.
    - `Tests/.../Support/Harness.swift` and `InitializationTests.swift` — `makeAgent()` is now async over the stub router; three call sites updated.
    `swift test`: 152 tests in 17 suites pass; the one "known issue" is the pre-existing deliberate `withKnownIssue` self-test in HarnessSmokeTests.

    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift, Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/Support/Harness.swift, Tests/FoundationModelsACPAgentTests/InitializationTests.swift
    - next: test, then commit and review
    task: ^nz60y96
  timestamp: 2026-09-02T00:37:43.351051+00:00
- actor: claude-code
  id: 01m1frvtr52wt9kn31qt8aqjph
  text: |-
    ### test — green
    - evidence: swift test (clean rebuild) — 152 tests in 17 suites passed, 0 failed, 0 skipped; zero warnings in this package's own Sources/ and Tests/ (the only warnings come from the vendored mlx-swift checkout); the one known issue is the deliberate withKnownIssue self-test in HarnessSmokeTests
    - next: commit, then review
    task: ^nz60y96
  timestamp: 2026-09-02T00:38:51.397968+00:00
- actor: claude-code
  id: 01m1frwb9zm7517je12k1sm7tb
  text: |-
    ### commit — changed
    - evidence: 6041c5e feat(profile): resolve the config profile to a resident profile at agent construction (8 files, 411 insertions, 32 deletions; local only, not pushed)
    - next: review 6041c5e (HEAD~1..HEAD)
    task: ^nz60y96
  timestamp: 2026-09-02T00:39:08.351305+00:00
- actor: claude-code
  id: 01m1fs3vy309v0wbcr66myv2wc
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 1 finding: Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift:69 (reuse/reuse — extract one shared test agent factory used by ProfileResolutionTests.makeAgent and Harness.makeAgent)
    - next: implement the finding, test, commit, review again
    task: ^nz60y96
  timestamp: 2026-09-02T00:43:14.755792+00:00
- actor: claude-code
  id: 01m1fs3xhjrwr19mw4735peb3h
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (6 files; ProfileResolution.swift, RoutedACPAgent init, tests, harness)
    - test: green (152 tests, 0 failed, 0 skipped, zero own-code warnings)
    - commit: 6041c5e
    - review: findings (1 — ProfileResolutionTests.swift:69 reuse/reuse)
  timestamp: 2026-09-02T00:43:16.402395+00:00
- actor: claude-code
  id: 01m1fs6cya14tear4z07qn3s6x
  text: |-
    Worked the review finding: extracted the shared factory `makeStubAgent(name:cacheDirectory:loader:)` in StubProfileFixtures.swift, beside makeStubRouter and makeStubProfile. Both Harness.makeAgent and ProfileResolutionTests.makeAgent now forward to it; neither constructs a router or an agent on its own.

    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/Support/Harness.swift, Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift
    - next: test, commit, review
    task: ^nz60y96
  timestamp: 2026-09-02T00:44:37.706911+00:00
- actor: claude-code
  id: 01m1fs6h7s8tr6914h6mvdpvd2
  text: |-
    ### test — green
    - evidence: swift test — 152 tests in 17 suites passed, 0 failed, 0 skipped; zero warnings in this package's own code
    - next: commit, then review
    task: ^nz60y96
  timestamp: 2026-09-02T00:44:42.105433+00:00
- actor: claude-code
  id: 01m1fs6rg47avmbc3ns2msrbj0
  text: |-
    ### commit — changed
    - evidence: 2ee3214 refactor(tests): route agent construction through one shared makeStubAgent factory (5 files, 96 insertions, 12 deletions; local only, not pushed)
    - next: review 2ee3214 (HEAD~1..HEAD)
    task: ^nz60y96
  timestamp: 2026-09-02T00:44:49.540648+00:00
- actor: claude-code
  id: 01m1fscbqv28s6hw862nh0em4j
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (2ee3214) — 0 findings, 1 candidate refuted; the one prior finding is checked; task moved to done
    task: ^nz60y96
  timestamp: 2026-09-02T00:47:53.083517+00:00
- actor: claude-code
  id: 01m1fscf1zf81d60p6zypstdw9
  text: |-
    ### finish iteration 2 — done
    - implement: changed (3 test files; shared makeStubAgent factory works the reuse finding)
    - test: green (152 tests, 0 failed, 0 skipped, zero own-code warnings)
    - commit: 2ee3214
    - review: clean (0 findings; prior finding checked; task moved to done)
  timestamp: 2026-09-02T00:47:56.479869+00:00
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
position_column: done
position_ordinal: 8b80
title: 'Profile resolution: ProfileDefinition from config, name fallback, resident profile'
---
## What
Plan.md §1 (the composition spine `config → ProfileDefinition → Router.resolve → resident profile`), §2.1 (the name's third consumer), §2.2 (layer-1 defaults).

Create `Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift`.

Map the decoded `profile` config section to Router's `ProfileDefinition`. **The initializer is:**

```swift
ProfileDefinition(name: String,
                  description: String,
                  standard: [ModelRef],
                  flash: [ModelRef],
                  embedding: [ModelRef],
                  context: Int? = 8192)
```

Note these facts:
- **Each slot is a candidate LIST, not one model.** `standard`, `flash` and `embedding` are `[ModelRef]`. Router measures the real RAM and GPU budget and picks the biggest candidate that fits each slot.
- **`description` is required.** Supply one.
- `context: nil` opts into ladder derivation from each candidate's native maximum context. The default is 8192.
- **`ModelRef` can only be built from a string literal or by decoding.** Its `repo`, `revision`, `init(repo:revision:)` and `init(_ string:)` are all internal. Read a value back only as `stringValue`. The separator is `@`, as in `"org/repo@rev"`. So the config decode path must produce `ModelRef` through `Codable`, never through a runtime string initializer.

Resolve with **`Router.resolve(profile:reporting:)`**. The label is `profile:`. Router's README shows `router.resolve(coding, reporting:)`, which does not compile; upstream carded that fix.

- `profile.name` falls back to the dotfolder `<name>` when it is not set. This is one of exactly three consumers of the name (§2.1). A configured name wins.
- Resolve to a resident profile when the agent is constructed. The in-code default configuration selects a coding profile that works on a 16 GB machine (§2.2 layer 1).
- **Hold the resident profile strongly for the life of the agent.** `LanguageModelProfile.init` is `package`, so `Router.resolve` is the only way to get one. Residency is pooled and reference counted. Each `RoutedModel` holds its owning profile weakly, and every public `makeSession` calls `preconditionFailure` if the profile was already released. Only the vended session retains it.
- Tests inject a scripted `ModelLoader`. Do no real resolution and no download.

**Error handling, corrected.** An earlier draft said no Router error type can be caught. That is wrong. `ResolutionFailure` — the error `resolve` throws when no candidate trio fits — IS internal, so catch `any Error` on the resolve path and report its message. But Router does publish catchable error types, and later tasks use them: `GenerationError`, `GuidedRequestError`, `ToolMountError`, `DiscoveryPrimingFailure`, and the `LostRunError` protocol. `LostRunError` matters most: a tool error that conforms makes the run settle `.lost`.

- [x] `profile` section → `ProfileDefinition` mapping, with candidate lists
- [x] `profile.name` → `<name>` fallback
- [x] Resolution through `Router.resolve(profile:reporting:)` at construction
- [x] The resident profile is held strongly and reaches session creation
- [x] The resolve path catches `any Error` and reports the message

## Acceptance Criteria
- [x] With no `profile.name` configured, the resolved profile name equals the dotfolder name; a configured name wins
- [x] A config listing three `standard` candidates produces a `ProfileDefinition` with three `ModelRef` values, asserted by `stringValue`
- [x] `context` omitted from config produces `nil`, not 8192, so the ladder applies
- [x] Agent construction with the default configuration resolves and touches no network, observed through the scripted loader
- [x] A scripted resolution failure surfaces as a reported error with a readable message
- [x] Two sequential sessions both construct, which proves the profile stayed alive and no `preconditionFailure` fired

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift` — the mapping matrix, the fallback, the failure path, and the construction path with the injected loader
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-01 19:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift:69` `reuse/reuse` — Reinvents agent construction logic duplicated in Harness.makeAgent. Both methods create a stub router and construct RoutedACPAgent using identical patterns; this shared capability should have one implementation. Extract a parameterized helper—e.g. makeTestAgent(name:cacheDirectory:loader:)—in StubProfileFixtures alongside makeStubRouter and makeStubProfile. Have ProfileResolutionTests.makeAgent and Harness.makeAgent call this shared factory.