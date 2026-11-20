---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7w01h6b4ftgrygctsaq2ess
  text: |-
    Research:
    - The shipped agent (`ComposedAgent.compose`) makes the router first, then calls `BundledProfiles.fallbackName(using: router)`, and gives the name to `ConfigurationLoader(fallbackProfileName:)` and to `RoutedACPAgent(fallbackProfileName:)`. The builtin config.yaml sets no profile.
    - `LiveAgent.makeHarness` (in-process, ToolCallingTests and SkillTrigger) made the loader before the router, with the default fallback `small`. Thus a config with no `preset` alone is not sufficient there: LiveAgent must make the same choice as ComposedAgent.
    - The spawned `acp-agent` (StdioContractTests) makes the shipped choice itself when no layer sets `profile`.
    - An empty user config.yaml is a null tree. `LayeredYAMLDocument.merge` replaces the lower tree with a higher value that is not a mapping, thus an empty file would remove the offline defaults layer (marketplaces: []). The fixture writes `{}` instead.
    - `skillTriggerModel` in SkillTriggerSubject.swift had no reader, and it needed a preset name. I removed it.
    - This Mac has 128 GB, so the fit choice is `large` here, the same models as before. The CI failure cannot be reproduced here, and no unit test can watch the fit choice of a live Router fail. The proof on mini-01 is the CI run.
  timestamp: 2026-11-20T08:09:22.379184+00:00
- actor: claude-code
  id: 01m7w1vm80w8swtt1z4dk7z95g
  text: |-
    ### implement — stuck
    - changed: 4 files under IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests: Support/LiveAgent.swift (makes the router first, calls `BundledProfiles.fallbackName(using: router)`, gives the name to `ConfigurationLoader(fallbackProfileName:)` and to `RoutedACPAgent(fallbackProfileName:)`, as `ComposedAgent` does), ToolCallingTests.swift (the config sets no profile), SkillTrigger/SkillTriggerSubject.swift (`skillTriggerPreset` is `String?`; the config sets `profile.preset` only when `ACP_AGENT_SKILL_TRIGGER_PRESET` is set; removed `skillTriggerModel`, which had no reader), Support/TierThreeFixture.swift (`userConfigYAML` is `{}`, so the spawned agent makes the shipped choice; doc comments updated). EmbeddingModelTests.swift is not changed: its suite passed.
    - evidence: `swift build --package-path IntegrationTests` -> "Build complete!" with no error and no warning (test item 1 checked). `swift test --package-path IntegrationTests --no-parallel`: 11 suites passed before SkillTriggerTests (CLIProcessTests, CapturedProcessRunTests, ChildDeadlineTests, ClientServerTests, EmbeddingModelTests, InterruptTests, KeychainSecretStoreTests, OutOfProcessTests, ProcessCensusTests, ProcessCensusExitStatusTests, SessionsSkillExamplesTests), 0 failed.
    - blocker: on this Mac the fit choice is `large` (as before the change). SkillTriggerTests then started a download of `mlx-community/Qwen3.8-27B-8bit` (the standard model of `large.yaml`, total 29.5 GB). The cache had only partial `.incomplete` blobs from 2026-11-19 (13 GB). The drafter `mlx-community/Qwen3.8-27B-MTP-8bit` is not in the cache. After 30 minutes the download was at about 3 GB more. The constraint of this step forbids new model downloads, so I stopped the run. SkillTriggerTests, ToolCallingTests and StdioContractTests did not run to an end. Test item 2 stays open. The test code before this change pins `large` too, so the same download is necessary for any full run on this Mac.
    - next: a person decides: permit the download of the `large` weights (about 16 GB more for the standard model, plus the MTP drafter) and run `swift test --package-path IntegrationTests --no-parallel` again, or accept the CI run as the proof.
  timestamp: 2026-11-20T08:41:06.048618+00:00
position_column: doing
position_ordinal: '8180'
title: 'CI integration is red on mini-01: the live tests pin the profile "large", which does not fit a 26.8 GB budget'
---
## Problem

CI run 44685358692 (e69894c), job "Integration (opt-in, real dependencies)", runner mini-01. 3 tests fail:

- SkillTriggerTests.swift:137 "A live model loads the skill that fits the task": `profile "large" did not resolve: ResolutionFailure: profile "large" cannot co-fit a budget of 26800603136 bytes.`
- ToolCallingTests.swift:92 "The shipped model writes a file and runs a shell command": the same error.
- StdioContractTests.swift:224 `framingSurvivesTheProcessBoundaryWhileAShellChildRuns`: `Caught error: .closed`. The probable cause is the same: the spawned agent reads the user config of `TierThreeFixture.writeUserConfig` (`preset: large`), the profile does not resolve, and the process closes the connection.

On runner m3u1 (more memory) the same tests pass. The tests write `preset: \(ModelProfiles.defaultName)` (`large`) in ToolCallingTests.swift:71, Support/TierThreeFixture.swift:186, and SkillTrigger/SkillTriggerSubject.swift:54. Since bdf13fe (^t2t3zww, D203) the shipped agent does not use `large` on each Mac: it uses `BundledProfiles.fallbackName(using:)`, the largest bundled profile that fits. `Router` conforms to `ProfileFitEstimating`. The tests do not use that choice.

## Work

1. The live integration tests use the same profile choice as the shipped agent: `BundledProfiles.fallbackName(using:)` with a Router as the fit source, or no `preset` in the written config so that the agent makes the choice. Keep the `SKILL_TRIGGER` environment override of SkillTriggerSubject, if it exists.
2. Make sure that StdioContractTests passes when the profile fits. If `.closed` has a different cause, find it.
3. Update the doc comments that say that the tests use `ModelProfiles.defaultName`.

## Tests

- [x] `swift build --package-path IntegrationTests` has no error and no warning.
- [ ] `swift test --package-path IntegrationTests --no-parallel` passes on this Mac.
- [ ] The CI integration job is green after the push (on mini-01 and on m3u1). #ci #bug