---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5axf9p0rtkjjk7vyekd9we9
  text: |-
    Research done. Findings:
    - `ToolsConfiguration` uses the synthesized `encode(to:)`. A `CodingKeys.agents` case with no stored property does not compile, thus `agents` leaves `CodingKeys`. The agents key stays known through a separate key constant and body-key set in the `tools:` schema check, so no "unknown tool section" warning comes.
    - `BuiltinConfigurationFileTests` iterates `CodingKeys.allCases` and `optionKeys`; with `agents` out of both, the builtin file needs no `tools.agents` section. `ConfigInitTests` and `DocumentationSyncTests` also iterate `CodingKeys`.
    - Disabled branches: `ToolCatalog.makeSkillsSource` (guard on `.enabled`), `makeSkillsRegistry` and `makeSkillsTool` (optional results), `makeStandaloneTools` (branch with no agents mount), `AgentsComposition.compose` (guard, optional `skills`). After the change `makeSkillsTool` has no caller, so it goes. `SessionSetup.compose` reads `skills?.registry`; it changes with the non-optional source.
    - `RuntimeDoctor` reads the configuration only for the disabled rows; after the change the stored configuration has no reader.
    - `SessionSetupTests.twoConcurrentSessionsReadDifferentProjectLayerConfig` used `skills: false` as its per-cwd example; it needs another tool section (shell).
    - README "Tools" text says `enabled: false` (or `agents: false`) turns the agents tool off; it needs an update.
    - `MountOrder.withoutSkillsNames` / `withoutAgentsNames` lose their users.
  timestamp: 2026-10-19T20:25:58.720225+00:00
- actor: claude-code
  id: 01m5axzgjs5fw5wphmgxx6n8ck
  text: |-
    Implementation landed (TDD: the new tests were written first; RED was a compile failure on the new API, then GREEN).
    - Codec: `ToolsConfiguration.skills` is `SkillsToolOptions`. A new internal `AlwaysOnToolSection<Options>` decodes a scalar boolean, `{}` or null to the defaults and a mapping to the options. `agents` left `CodingKeys` and the property is gone; `ToolsConfiguration.agentsKey` and `agentsBodyKeys` (`enabled`) keep the key known. `AgentsToolOptions` is gone.
    - Loader: new `ConfigurationWarning.cannotDisable(section:)`, with description, log message and section key path. `schemaWarning(forTool:body:)` gives it for `skills: false`, `agents: false` and `agents.enabled: false`. `ConfigurationDoctor` now reads `warning.sectionKeyPath` in place of its own copy of the same switch.
    - Catalog: `makeSkillsSource` returns `SkillsSource` (not optional); `makeSkillsRegistry` and `makeSkillsTool` are deleted (no production caller remained); `makeStandaloneTools(agents:)` gives `[environment.skillsTool, agents.tool]`; `AgentsComposition.compose` takes a non-optional source and returns `AgentsMount`. `SessionSurface.agents` stays optional, because the empty surface of a replay-only session has no mount. `SessionSetup` reads `skills.registry`.
    - Doctor: `RuntimeDoctor` has no disabled rows and no configuration. Its init is now `init(workingDirectory:environment:)`, and `DoctorCommand` is updated.
    - Builtin config: no `tools.agents` section; the header and the skills comment say that both tools are always on. README updated.
    - Tests: decode and warning tests added; the disabled-state tests are removed; `SessionSetupTests` per-cwd test now uses `shell: false`; `MountOrder.withoutSkillsNames`/`withoutAgentsNames` are removed.
    Note: the full run shows a SwiftPM build-system line, "warning: missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It is not a compiler warning from this diff. The one known issue is the intended `withKnownIssue` in `HarnessSmokeTests`.
  timestamp: 2026-10-19T20:34:50.073277+00:00
- actor: claude-code
  id: 01m5axzm9bs1hjcnpbhthg2bch
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0, 987 tests in 111 suites passed, 0 failures (1 intended known issue in HarnessSmokeTests). 22 files: README.md, Sources/FoundationModelsACPAgent/{Agent/SessionSetup.swift, Configuration/ConfigurationLoader.swift, Configuration/ToolSectionCodec.swift, Doctor/ConfigurationDoctor.swift, Doctor/DisabledSectionCheck.swift, Doctor/RuntimeDoctor.swift, Resources/builtin.config.yaml, Tools/AgentsComposition.swift, Tools/ToolCatalog.swift}, Sources/acp-agent/DoctorCommand.swift, Tests/FoundationModelsACPAgentTestSupport/AgentConfigurationWithoutMarketplaces.swift, Tests/FoundationModelsACPAgentTests/{AgentsToolTests, ConfigurationLoaderTests, Doctor/RuntimeDoctorTests, Integration/SkillsLibraryTests, SessionSetupTests, SkillsMarketplaceTests, Support/MountOrder, ToolCatalogTests, ToolSectionCodecTests}.swift
    - next: /review
  timestamp: 2026-10-19T20:34:53.867871+00:00
- actor: claude-code
  id: 01m5ay2j7kk0jhbj4kxr9s59dn
  text: |-
    ### test — green
    - evidence: `swift test` exit 0, 987 tests in 111 suites passed, 0 failed, 0 skipped. 1 known issue: the intended `withKnownIssue` in HarnessSmokeTests (orderedSubsequenceAssertionChecksOrderWithGaps). No Swift compiler warning. One SwiftPM build-system line, "warning: missing creator for mutated node" for mlx-swift_Cmlx.bundle, is not from this change.
    - next: /review
  timestamp: 2026-10-19T20:36:30.067230+00:00
position_column: doing
position_ordinal: '80'
title: 'Skills and agents are always on: the config cannot turn them off'
---
## What
The config can now turn off the skills tool (`tools.skills: false`) and the `agents` tool (`tools.agents: false` or `tools.agents.enabled: false`). The user decided on 2026-10-19 that both are always on. A config that tries to turn one off still loads: the loader gives a `ConfigurationWarning`, and the tool stays on.

- `Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift`:
  - `ToolsConfiguration.skills` becomes `SkillsToolOptions` (not `ToolSection<SkillsToolOptions>`). `tools.skills.marketplaces: []` still turns the remote marketplaces off; the skills tool stays on.
  - Remove `ToolsConfiguration.agents` and the `AgentsToolOptions` typealias. The section has no option other than `enabled`.
  - Decode: a scalar `tools.skills: false` (or `true`, `{}`, null) gives `SkillsToolOptions()` with the defaults. A mapping gives the decoded options.
  - Keep `skills` and `agents` in the known tool keys, so that they do not give the "unknown tool section" warning.
- `Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift`: add a `ConfigurationWarning` case, for example `cannotDisable(section:)`, for `tools.skills: false`, `tools.agents: false` and `tools.agents.enabled: false`. Give it in `schemaWarnings(in:)`, with its log record. A `tools.agents` mapping with another key is an unknown key, as now for a checked section.
- `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`: remove the `tools.agents` section. Change the comment of `tools.skills` so it does not say that it can be off.
- `Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift` (`compose`): remove the `tools.agents.mountedOptions` guard. `Tools/ToolCatalog.swift` and `Tools/SkillsSource.swift`: remove each branch for disabled skills.
- `Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift`: remove the "disabled" rows of skills and agents, and their doc comments.
- Tests that set `configuration.tools.skills = .disabled` only to stay hermetic (`ToolCatalogTests`, `AgentsToolTests`, `Integration/SkillsLibraryTests`): use `SkillsToolOptions(marketplaces: [])`, as `Tests/FoundationModelsACPAgentTestSupport/AgentConfigurationWithoutMarketplaces.swift` does. Remove the tests that check the disabled state.

## Acceptance Criteria
- [ ] `ToolsConfiguration` has no way to turn off skills or agents: the types have no disabled state.
- [ ] A config with `tools.skills: false` loads, gives one `cannotDisable` warning for `tools.skills`, and the session has the skills tool.
- [ ] A config with `tools.agents: false`, and one with `tools.agents.enabled: false`, each load, give one `cannotDisable` warning for `tools.agents`, and the session has the `agents` tool.
- [ ] `tools.skills.marketplaces: []` gives no warning and no remote marketplace.
- [ ] The builtin config has no `tools.agents` section, and the builtin key tests pass.
- [ ] `acp-agent doctor` shows no "disabled" row for skills or agents.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift`: the decode of each scalar and mapping form of `tools.skills`, and of `tools.agents`.
- [ ] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` (or the suite that tests `schemaWarnings` now): the three `cannotDisable` warnings.
- [ ] `Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift` and `ToolCatalogTests.swift`: a config that tries to turn off agents or skills still mounts the tool.
- [ ] `Tests/FoundationModelsACPAgentTests/Doctor/RuntimeDoctorTests.swift`: remove the disabled-row tests, and keep the layer rows.
- [ ] Run `swift test`. All tests pass with no warnings.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement. #config