---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d98kack6rarp7wmzjrrq7f
  text: |-
    Research done. Discoveries:
    - The stacks of the library: `ConfigurationLoader.init` (configuration; `TranscriptsDoctor`, `ConfigCommand.Path`, `LayerFileWriter`, `InstructionsAssembler` and `SessionSetup.userLayerRoot` all read `loader.stack`), `ToolCatalog.makeSkillsSource` (skills), `AgentsComposition.makeAgentRegistry` (agents), `RuntimeDoctor.dotfolderStack(named:)` (skills and agents rows).
    - Plan: `SettingsFolders(name:rootSettingsFolder:environment:)`. With no root, `stack(for:)` gives `DotfolderStack(name:workingDirectory:environment:)` (the old list). With a root, `DotfolderStack(layers:)`: the defaults layer of `<NAME>_DEFAULTS_DIR` (the test suites need it; it is not in `~` or XDG), the user layer in the root, the project dotfolder of the cwd.
    - `ConfigurationLoader` keeps the `userDirectory:` init (many tests call it). A user directory is the same as a root settings folder for the configuration kind, so that init gives `SettingsFolders(rootSettingsFolder: userDirectory)`.
    - `RoutedACPAgent.userDirectory` has one production caller less after the change; `makeStubAgent(userDirectory:)` gives it as `rootSettingsFolder:`. Effect on the tests: the skills user layer goes from the real `~/.config/skills` to `<userDirectory>/_skills` (more hermetic).
    - The agents stack also goes through `SettingsFolders` here, because the card says that with a root no stack has a folder in `~` or XDG. Card ^05sszw4 keeps the AG-10 dependency update and the `agentFolders` removal.
    - `CatalogContext` gets the `SettingsFolders` of the agent, because the skills and agents stacks are made from it.
    - Not a stack, so out of scope: the skills marketplace cache (`MarketplaceStore.cacheDirectory`, under the home folder when `SKILLS_MARKETPLACE_CACHE` is not set), the hooks data directory (the host gives `hooksDataDirectory`), and the model cache of `ModelResolver`.
  timestamp: 2026-10-20T18:30:30.988672+00:00
- actor: claude-code
  id: 01m5d9w5t69zj8at44v5g5901g
  text: |-
    Implementation landed (TDD: the new tests failed to compile first, then passed).
    - New `SettingsFolders` (`Configuration/SettingsFolders.swift`): `Kind` = configuration, skills, agents, rules; `stack(for:workingDirectory:)`. With a root it uses `DotfolderStack.init(layers:)`: the `<NAME>_DEFAULTS_DIR` defaults layer, the user layer `<root>/`, `<root>/_skills/`, `<root>/_rules/` or `<root>/` (agents), and the project dotfolder `<cwd>/.<name>/`. With no root it gives `DotfolderStack(name:workingDirectory:environment:)` (the old list).
    - `ConfigurationLoader` has `init(settingsFolders:workingDirectory:transcriptLocation:secretStore:)` and a `settingsFolders` property. The old `userDirectory:` init stays (many tests call it); it gives the user directory as the root settings folder, which is the same user layer for `config.yaml`.
    - `RoutedACPAgent.init(rootSettingsFolder:)` replaces `userDirectory:` (no caller needed the old parameter: `makeStubAgent(userDirectory:)` and `LiveAgent` now give it as the root). `ComposedAgent.compose(rootSettingsFolder:)` added.
    - `CatalogContext` takes `settingsFolders:`; `ToolCatalog.makeSkillsSource` and `AgentsComposition.makeAgentRegistry` use it. `RuntimeDoctor.init(workingDirectory:settingsFolders:)`; `doctor` gives `loader.settingsFolders`. `config path`, `TranscriptsDoctor`, `LayerFileWriter` and `InstructionsAssembler` read `loader.stack`, which now comes from `SettingsFolders`.
    - Test support: `composeStubAgent(rootSettingsFolder:configHome:)`; new `SettingsFoldersFixture.make(label:environment:)` so each test `CatalogContext` uses a temporary root (no test context reads `~/.config/skills` now).
    - README: new section "Settings folders".
    - Gotcha: `URL.standardizedFileURL` maps `/private/tmp` to `/tmp`; compare standardized paths on both sides in tests.
  timestamp: 2026-10-20T18:41:12.518776+00:00
- actor: claude-code
  id: 01m5d9wqykvdkpnbtfk6vytv9f
  text: |-
    ### implement — changed
    - evidence: `swift test` 1053 tests in 116 suites passed (1 known issue: the existing `withKnownIssue` in HarnessSmokeTests; the one build warning is the SwiftPM "missing creator" note of the mlx bundle, not a source warning). `swift build --build-tests --package-path IntegrationTests` clean. New files: Sources/FoundationModelsACPAgent/Configuration/SettingsFolders.swift, Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift (8 tests, 17 cases), Tests/FoundationModelsACPAgentTestSupport/SettingsFoldersFixture.swift. Changed: ConfigurationLoader, RoutedACPAgent, SessionSetup, ComposedAgent, CatalogContext, ToolCatalog, AgentsComposition, RuntimeDoctor, ConfigurationLayerName, GatedStubModel (doc link), acp-agent AgentComposition and DoctorCommand, README, test support StubComposition and StubProfileFixtures, LiveAgent, and 9 test files (CatalogContext call sites, RuntimeDoctorTests, SessionResumeTests).
    - next: /review
  timestamp: 2026-10-20T18:41:31.091486+00:00
- actor: claude-code
  id: 01m5da0kwntg2mkkq4jptd59x5
  text: |-
    ### test — green
    - evidence: touched all changed Swift files, then `swift test` — 1053 tests in 116 suites passed, 0 failed, 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps, accepted); no compiler warning in the rebuilt targets; `swift build` complete; `swift build --build-tests --package-path IntegrationTests` complete with no compiler warning. Only warning: SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx (accepted).
    - next: review
  timestamp: 2026-10-20T18:43:38.005089+00:00
position_column: doing
position_ordinal: '8280'
title: 'ACPA-16: one list of folders from the host for config, Instructions.md and skills'
---
## What
ACPA-16 and D98: ACPAgent makes all its stacks with `DotfolderStack` from one list of folders, at two levels above the built-in layer: the user level (a root settings folder that the constructor takes; in the app `<iCloud container>/Agents/`) and the session level (the cwd of each `session/new`, `session/resume` and launcher start). The session level wins. With a root from the host, ACPAgent reads no folder in `~` and no `XDG_CONFIG_HOME`. The CLI gives no root, so it keeps its XDG folders.

Now ACPAgent makes separate stacks from bare names:
- `config.yaml` and `Instructions.md`: `ConfigurationLoader` (`Configuration/ConfigurationLoader.swift:143-219`) with `DotfolderStack(name: "acp-agent", ...)`. The factory is `RoutedACPAgent.makeConfigurationLoader(workingDirectory:)` (`SessionSetup.swift:793`). `InstructionsAssembler` uses `context.loader.stack` (`SessionSetup.swift:893`).
- Skills: `ToolCatalog.makeSkillsSource` (`ToolCatalog.swift:552-568`) with `DotfolderStack(name: "skills", ...)`.
- Also `RuntimeDoctor.swift:132`, `TranscriptsDoctor`, `ConfigCommand.Path` (line 341) and `LayerFileWriter` build stacks.

Do this:
- Add a type `SettingsFolders` (in `Configuration/`) that gives the layers for one cwd: `func stack(for kind: Kind, workingDirectory: URL) -> DotfolderStack`, with `Kind` = `.configuration`, `.skills`, `.agents`, `.rules`. Use `DotfolderStack.init(layers:)` (Extras `DotfolderStack.swift:180`), lowest layer first: built-in, user, project.
- With a root from the host: the user layer of `.configuration` is `<root>/`, and the user layers of the other kinds are folders in `<root>` whose names are never a valid agent id. Use `<root>/_skills/` and `<root>/_rules/` (as `_rules/` and `_partials/`). Agents are `<root>/<id>/` (the next card). The project layers stay the project dotfolders of the cwd (`.acp-agent/`, `.skills/`, ...).
- With no root (the CLI): the layers are the same as now (XDG user folder, project dotfolder).
- Add `rootSettingsFolder: URL? = nil` to the `RoutedACPAgent` init (`RoutedACPAgent.swift:288-313`; it replaces the narrow `userDirectory`, keep the old parameter only if a caller still needs it) and to `ComposedAgent.compose`.
- Use `SettingsFolders` in each place above. Every stack in the library comes from it, so no code path reads `~` or `XDG_CONFIG_HOME` when the root is set.
- The rules kind: FoundationModelsRules has no code yet, so only define the kind and the folder name. Do not add a dependency.
- Document the folder names in README.md.

## Acceptance Criteria
- [x] With a root, `config.yaml`, `Instructions.md` and the skills come from `<root>` and the cwd, and the cwd wins.
- [x] With a root, no stack contains a folder in `~` or `XDG_CONFIG_HOME`, also when `HOME` and `XDG_CONFIG_HOME` point to folders with a `config.yaml`.
- [x] With no root, the layers are the same as before.
- [x] `doctor` and `config path` show the layers of `SettingsFolders`.

## Tests
- [x] A test with a temporary root, a temporary cwd and a temporary `XDG_CONFIG_HOME`: a key set in all three has the cwd value; a key set only in XDG is not set.
- [x] A test that a skill in `<root>/_skills/` and a skill with the same name in the cwd give the cwd skill.
- [x] A test with no root keeps the old layer list.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-16