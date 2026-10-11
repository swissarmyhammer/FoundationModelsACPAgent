---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4m3z11yy62ymkrgqe035tq3
  text: |-
    Research:
    - `PipedChildProcess.init` is the one launch setup of `BuiltExecutableRun`, `SignalledExecutableRun` and `SpawnedACPAgent`. These cover 8 spawned suites. Many of them write no user config, and some write their own YAML (broken config, malformed profile). Thus the user layer of `TierThreeFixture` does not cover every suite. A defaults layer through `PipedChildProcess` does.
    - `DotfolderStack` reads `<NAME>_DEFAULTS_DIR` (here `ACP-AGENT_DEFAULTS_DIR`). The agent passes no defaults folder of its own, so this layer adds and removes nothing else. An empty value names no defaults layer. A test uses this to get the shipped marketplace list back.
    - `StdioContractTests` spawns with `AgentProcess` of the client package. It reads the environment of this process (setenv), not `PipedChildProcess`. It must set the same pair.
    - `ClientInteropTests` composes in this process with `StubAgentDefaultsLayer` already (marketplaces: []).
    - `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` counts three layer rows. A defaults layer adds a row. That test must remove the layer (empty value), because it proves the rows of a stock install.
    - `StubAgentDefaultsLayer` also turns the code context off. The spawned children must keep their code context, so the offline layer sets only `tools.skills.marketplaces: []`.
  timestamp: 2026-10-10T23:56:53.694424+00:00
- actor: claude-code
  id: 01m4m48t4y1rb4z0jhhx538g7f
  text: |-
    Implementation landed (TDD):
    - RED: new `SkillsMarketplaceProcessTests.aSpawnedAgentFetchesNoSkillsMarketplace` failed before the change ("Expectation failed: try Self.entries(of: cache).isEmpty"). The child wrote a fetch into its cache folder.
    - GREEN: `TierThreeFixture.makeOfflineDefaultsEnvironment()` writes the offline defaults layer; `PipedChildProcess.init` merges it under the pairs of the caller; `StdioContractTests.pointEnvironment(at:)` sets it on this process for `AgentProcess`. Both tests of the new suite passed (offline 0.74 s, shipped list 1.74 s).
    - Checked by hand: `acp-agent config path` writes a `defaults` row when `ACP-AGENT_DEFAULTS_DIR` is set, and no row without it. Thus `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` gives `noDefaultsLayerValue` to keep the three rows of a stock install.
  timestamp: 2026-10-11T00:02:14.302748+00:00
- actor: claude-code
  id: 01m4m52kb8dnj0fkwft2b8ywb7
  text: |-
    ### implement — changed
    - evidence: 5 files — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TierThreeFixture.swift, Support/PipedChildProcess.swift, StdioContractTests.swift, CLIProcessTests.swift, SkillsMarketplaceProcessTests.swift (new).
    - probe run: `SKILLS_MARKETPLACE_CACHE=<scratch>/probe swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel --skip theShippedMarketplaceListFetchesTheGitHubSkillsRepositoryOverTheNetwork` — 34 tests in 13 suites passed; the probe folder holds 0 entries.
    - full run: same command with no `--skip` — 35 tests in 13 suites passed; the process cache folder holds 0 entries (the default-path test uses its own cache folder).
    - root run: `swift test --scratch-path .build/alt --force-resolved-versions` — 886 tests in 97 suites passed, 1 known issue (the `withKnownIssue` of `HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps`, there before this change); its cache folder holds 0 entries. `AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses` (^05rmb1p) passed.
    - warning: each build writes the SwiftPM warning "missing creator for mutated node" for the mlx-swift_Cmlx bundle. It was in the RED log before the change. New task ^tvjz12j records it.
    - the doc comment of the `StdioContractTests` suite changed after the runs (comment only, no code).
    - next: /review
  timestamp: 2026-10-11T00:16:19.304064+00:00
- actor: claude-code
  id: 01m4m5ecxf92sys52w8g84kcf3
  text: |-
    ### test — green
    - evidence: `swift test --scratch-path .build/alt --force-resolved-versions` — 886 tests in 97 suites passed, 0 failed, 0 skipped. 1 known issue: it is the planned `withKnownIssue` in HarnessSmokeTests (orderedSubsequenceAssertionChecksOrderWithGaps), not a failure.
    - evidence: `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` — 35 tests in 13 suites passed, 0 failed, 0 skipped.
    - cache: each run had its own new empty SKILLS_MARKETPLACE_CACHE folder. Entry count after the unit run: 0. Entry count after the integration run: 0.
    - warnings: only the mlx-swift "missing creator for mutated node" warning, tracked by ^tvjz12j. It is not fixed here.
    - flaky test: AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses passed in this run. No change made.
    - next: none. No file was changed, staged, or committed.
  timestamp: 2026-10-11T00:22:45.935156+00:00
- actor: claude-code
  id: 01m4m6p064wh0rbkhqgk4r3tgc
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 6e9bec7). counts: 1 finding, 1 confirmed, 0 refuted. Finding: IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SkillsMarketplaceProcessTests.swift:50 (reuse/reuse).
    - acceptance check (2026-10-10): all 5 items are met.
      - A `--no-parallel` IntegrationTests run with `--skip theShippedMarketplaceListFetchesTheGitHubSkillsRepositoryOverTheNetwork` and an empty probe `SKILLS_MARKETPLACE_CACHE`: exit 0, 34 tests in 13 suites passed. The probe folder holds 0 entries.
      - A full `--no-parallel` IntegrationTests run: exit 0, 35 tests in 13 suites passed. The default-path test passed.
      - The root suite (`--scratch-path .build/alt --force-resolved-versions`, empty probe cache): exit 0, 886 tests in 97 suites passed, with 1 known issue. The probe folder holds 0 entries.
      - Both builds show the SwiftPM build-system warning "missing creator for mutated node" on the `mlx-swift_Cmlx.bundle` product. This change does not touch it.
    - next: move the shared subprocess driver of `runPrompt` and `CLIProcessTests.runAgentCLI` into `Support/`, then run `/review` again.
  timestamp: 2026-10-11T00:44:23.620809+00:00
- actor: claude-code
  id: 01m4m6ze8j6kms9zyjrf24htce
  text: 'Picked up the reuse finding. Research: `BuiltExecutableRun.run` with `TierThreeFixture.agentExecutableName`, a fresh workspace and a fresh config home also occurs in OutOfProcessTests, ClientInteropTests and TranscriptRecordingTests. The order limits this fix to `CLIProcessTests.runAgentCLI` and `SkillsMarketplaceProcessTests.runPrompt`, thus those other suites stay as they are. The new shared driver is `BuiltExecutableRun.runAgent(arguments:label:configHome:environment:)` in `Support/BuiltExecutableRun.swift`. This is a refactor of test support with no change of behavior; the existing tests of the two suites are the proof, so no new RED test applies.'
  timestamp: 2026-10-11T00:49:32.946788+00:00
- actor: claude-code
  id: 01m4m77w34c8ffbdanp87n984r
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/BuiltExecutableRun.swift (new `runAgent(arguments:label:configHome:environment:)`), CLIProcessTests.swift (`runAgentCLI` calls it), SkillsMarketplaceProcessTests.swift (`runPrompt` calls it; the stub-model and cache pairs stay at the call site).
    - run: `SKILLS_MARKETPLACE_CACHE=<scratch>/cache-8zjqm5d-fix swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel` — 35 tests in 13 suites passed. The cache folder holds 0 entries after the run.
    - warnings: only the SwiftPM "missing creator for mutated node" warning for mlx-swift_Cmlx.bundle (^tvjz12j). No compiler warning.
    - the review finding box is checked.
    - next: /review
  timestamp: 2026-10-11T00:54:09.252019+00:00
- actor: claude-code
  id: 01m4m7gv3w0aaps42swxm09723
  text: |-
    ### implement — changed
    - The coordinator asked for the same refactor in three more suites.
    - evidence: 3 more files. `OutOfProcessTests.runAgentCLI` and `ClientInteropTests.runAgentCLI` now call `BuiltExecutableRun.runAgent`. The header comment of `Support/BuiltExecutableRun.swift` names the new users.
    - Not moved: `TranscriptRecordingTests.runAgent`. The test reads the recording root under the workspace, and the resume case uses the same workspace and config home for two runs. `runAgent` makes its workspace inside the helper and does not return it, so this call cannot use it. Also not moved: `OutOfProcessTests.runPacedAgentCLI`, because it calls `SignalledExecutableRun.run` (signals, first-output probe), not `BuiltExecutableRun.run`.
    - run: `SKILLS_MARKETPLACE_CACHE=<scratch>/cache-8zjqm5d-fix2 swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel`: 35 tests in 13 suites passed. The cache folder holds 0 entries after the run.
    - warnings: only the mlx-swift_Cmlx "missing creator for mutated node" warning (^tvjz12j).
    - next: /review
  timestamp: 2026-10-11T00:59:03.164533+00:00
- actor: claude-code
  id: 01m4m7yss7vt4wgcesrr7h8f2n
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~2..HEAD` (6e9bec7, 6bf3fba). 8 files reviewed, 7 validator runs, 0 failed. Counts: findings 0, confirmed 0, refuted 1. The prior reuse finding at `SkillsMarketplaceProcessTests.swift:50` is resolved: `runPrompt` and `CLIProcessTests.runAgentCLI` both call the shared driver `BuiltExecutableRun.runAgent`. All prior findings are checked. All acceptance items stay checked.
    - next: none. The task moved to done.
  timestamp: 2026-10-11T01:06:40.551390+00:00
position_column: done
position_ordinal: ffbc80
title: 'IntegrationTests: the spawned acp-agent binaries fetch the default skills marketplace from GitHub'
---
## State now

Task ^t87yzmg made the `main` branch of `swissarmyhammer/skills` (HTTPS) the default of `tools.skills.marketplaces`. A session start fetches each marketplace.

- The unit target uses no network: `StubAgentDefaultsLayer`, `AgentConfiguration.withoutMarketplaces` and `ConfigCommandFixture.makeStubEnvironment()` set `marketplaces: []`. A full root run with `SKILLS_MARKETPLACE_CACHE` set to an empty folder left the folder empty.
- `ToolCallingTests` and `SkillTriggerTests` (in-process `LiveAgent`) set `marketplaces: []` in their user layer.
- The suites of `IntegrationTests` that spawn the built binary (CLIProcessTests, ClientInteropTests, ClientServerTests, InterruptTests, OutOfProcessTests, StdioContractTests, TelemetryFlushTests, TelemetryStdoutTests, TranscriptRecordingTests) use the default configuration. A run on 2026-10-10 with `SKILLS_MARKETPLACE_CACHE` set to an empty folder wrote a snapshot of `swissarmyhammer/skills` at `main` into that folder. All 28 tests passed.

## Decision (made 2026-10-10)

The end-to-end suites of `IntegrationTests` must be offline and repeatable. They must not fetch the real default marketplace.

- `TierThreeFixture` holds the one offline defaults layer: a `config.yaml` with `tools.skills.marketplaces: []`, named by `ACP-AGENT_DEFAULTS_DIR` (`defaultsDirectoryVariable`, `makeOfflineDefaultsEnvironment()`). The agent passes no defaults folder of its own, so this layer changes nothing else.
- `PipedChildProcess` gives this layer to each child it spawns (`BuiltExecutableRun`, `SignalledExecutableRun`, `SpawnedACPAgent`). A pair of the caller replaces it. The value `TierThreeFixture.noDefaultsLayerValue` (empty) removes the layer.
- `StdioContractTests` spawns through `AgentProcess`, which reads the environment of this process. It sets the same pair of `TierThreeFixture`.
- `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` removes the layer, because it proves the three layer rows of a stock install. `config path` starts no session, so it fetches nothing.
- One test proves the default marketplace path on purpose, and it uses the network: `SkillsMarketplaceProcessTests.theShippedMarketplaceListFetchesTheGitHubSkillsRepositoryOverTheNetwork`. It stays in the default run. `SkillsMarketplaceProcessTests.aSpawnedAgentFetchesNoSkillsMarketplace` proves the offline rule.

## Acceptance

- [x] Each child that the IntegrationTests suites spawn reads an empty marketplace list from one shared place.
- [x] One test proves the default marketplace path on purpose, with a name that states its purpose, in the default run.
- [x] A `--no-parallel` IntegrationTests run with a probe cache folder, and the default-path test skipped, leaves the probe folder empty.
- [x] A full `--no-parallel` IntegrationTests run passes.
- [x] The root suite passes.

#tests #config

## Review Findings (2026-10-10 19:23)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SkillsMarketplaceProcessTests.swift:50` `reuse/reuse` — The new `runPrompt` repeats the subprocess driver of `CLIProcessTests.runAgentCLI`: the same `BuiltExecutableRun.run` call with an agent executable, a fresh workspace, and a fresh config home. The only differences are the arguments, the stub-model environment, and the cache variable. Two copies of this driver can drift apart, so one canonical driver is the better design. Move the shared driver into `Support/` (for example, next to `TierThreeFixture`) as one helper that takes the arguments and the extra environment pairs. Let `runAgentCLI` and `runPrompt` each call it with their own arguments and environment. Keep the stub-model and cache pairs at the call site in `runPrompt`.
