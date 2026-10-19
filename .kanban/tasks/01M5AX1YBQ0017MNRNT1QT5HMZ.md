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
- actor: claude-code
  id: 01m5ay9ns94908evgptka7aenj
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (769a6a4); 1 finding (1 confirmed, 4 refuted) — Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift:401 `completeness/inverse-operation-coverage`.
    - card check: the diff agrees with each item of the card. The README and builtin.config.yaml have no validator; a manual check of their diffs found no text that says skills or agents can be off. No reference to makeSkillsRegistry, makeSkillsTool or AgentsToolOptions stays in Sources or Tests.
    - next: add the read-back test of the `config init` document (write, load, compare `tools` with the builtin `tools`, and check that the other tool sections are present). Then do a new review.
  timestamp: 2026-10-19T20:40:23.081179+00:00
- actor: wballard
  id: 01m5ayad3dx0mkcew85ae38grq
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 22 files
    - test: green — swift test, 987 passed, 0 failed
    - commit: 769a6a4
    - review: findings — Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift:401
  timestamp: 2026-10-19T20:40:46.957399+00:00
- actor: claude-code
  id: 01m5ayfyp91ttgz4nyz35rsfnw
  text: |-
    Finding fixed. `theConfigInitDocumentHasNoAgentsSection` is now `theConfigInitDocumentHasNoAgentsSectionAndReadsBack`. The test writes the builtin document with `ConfigurationYAML.documentText`, loads it with `fixture.loadProjectConfig(text)`, and asserts that the loaded `tools` equals the builtin `tools`. It also asserts that the document has a `\n  <key>:` section for each `ToolsConfiguration.CodingKeys` case, so the absence check cannot pass on an empty document.
    - TDD note: the change adds coverage of behavior that exists. Thus the new assertions passed on the first run, and there was no RED step.
    - Discovery: `ToolsConfiguration.agentsKey` is internal, and this test file uses a plain `import` (not `@testable`). Thus the test uses the literal `agents`.
    - The subtask boxes are now checked. Each item has a test or a source change in 769a6a4: ConfigurationLoaderTests `alwaysOnOffEntries` (three `cannotDisable` warnings), ToolCatalogTests `aConfigThatTurnsTheSkillsToolOffStillMountsTheSkillsTool`, AgentsToolTests `aConfigThatTurnsTheAgentsToolOffStillMountsTheAgentsTool`, RuntimeDoctorTests `eachRowIsALayerRowAndNoRowSaysDisabled`, builtin.config.yaml with no `agents` section.
  timestamp: 2026-10-19T20:43:48.809447+00:00
- actor: claude-code
  id: 01m5ayg0x7am4n4rg0915ed892
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift. `swift test` exit 0: 987 tests in 111 suites passed, 0 failed, and 1 intended known issue in HarnessSmokeTests. No Swift compiler warning. The SwiftPM line "warning: missing creator for mutated node" for mlx-swift_Cmlx.bundle comes from the build system and is not from this change.
    - next: /review
  timestamp: 2026-10-19T20:43:51.079456+00:00
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
- [x] `ToolsConfiguration` has no way to turn off skills or agents: the types have no disabled state.
- [x] A config with `tools.skills: false` loads, gives one `cannotDisable` warning for `tools.skills`, and the session has the skills tool.
- [x] A config with `tools.agents: false`, and one with `tools.agents.enabled: false`, each load, give one `cannotDisable` warning for `tools.agents`, and the session has the `agents` tool.
- [x] `tools.skills.marketplaces: []` gives no warning and no remote marketplace.
- [x] The builtin config has no `tools.agents` section, and the builtin key tests pass.
- [x] `acp-agent doctor` shows no "disabled" row for skills or agents.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift`: the decode of each scalar and mapping form of `tools.skills`, and of `tools.agents`.
- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` (or the suite that tests `schemaWarnings` now): the three `cannotDisable` warnings.
- [x] `Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift` and `ToolCatalogTests.swift`: a config that tries to turn off agents or skills still mounts the tool.
- [x] `Tests/FoundationModelsACPAgentTests/Doctor/RuntimeDoctorTests.swift`: remove the disabled-row tests, and keep the layer rows.
- [x] Run `swift test`. All tests pass with no warnings.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement. #config

## Review Findings (2026-10-19 15:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 19 file(s) reviewed, 10 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift:401` `completeness/inverse-operation-coverage` — The change makes `config init` omit `tools.agents` (the write side), but the new test only checks that the written text lacks an agents section. No test reads the written document back through the loader to confirm it still loads to the builtin configuration with the agents tool on. The deleted test `eachOffShapeOfTheAgentsSectionReadsBackTheSame` covered that read-back, and the replacement does not. The sibling test `theConfigInitDocumentReadsBackWithTheSectionOn` covers only the switch-only sections, not agents. Add a read-back check: write the builtin document with `ConfigurationYAML.documentText`, load it with `fixture.loadProjectConfig(text)`, and assert the loaded `tools` equals the builtin `tools`. Also assert the document contains the other tool sections, so the absence check cannot pass on an empty document.
