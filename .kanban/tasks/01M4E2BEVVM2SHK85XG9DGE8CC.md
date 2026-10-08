---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ef1psg2d56egkqknr964fa
  text: |-
    Research:
    - `ConfigurationLoader.load()` merges `config.yaml` with `LayeredYAMLDocument.load` over a user+project `DotfolderStack`. The Extras merge function is private, so the loader must merge the builtin tree under the layered root itself (same family rule: mappings merge by key, other values replace).
    - Do not use the `defaults` layer of `DotfolderStack` for the builtin file: its source is `.defaults` (config show would say "defaults", not "builtin"), it renders trusted, and `ACP_AGENT_DEFAULTS_DIR` replaces it. The sources map must stay from the layered document only, so a key that no layer sets still maps to `builtin`.
    - Only `web` and `git` (SwitchableToolOptions) accept `enabled:`. `files`, `shell`, `skills`, `codeContext` refuse an unknown key, and `mcp` is a list. Thus `enabled: true` goes on web and git only; a mapping body turns the other groups on.
    - Optional option values (`files.exclude`, `shell.storeDirectory`) must be `null` in the file, so the file decodes to exactly `AgentConfiguration()`. `web.apiKeys` is `{}` (no secret).
    - `ToolsConfiguration.optionKeys` is private; the test needs it internal (tests use `@testable import`).
    - `config path` prints the builtin row as "(in code, no file)". After this change that text is not true. It is not in the card scope; I add a new task for it.
    - `IntegrationTests` `CLIProcessTests.configShowWritesTheConfigurationToStdoutAndExitsZero` spawns the built binary and loads the configuration, so it proves `Bundle.module` in the binary.
  timestamp: 2026-10-08T19:15:09.232392+00:00
- actor: claude-code
  id: 01m4efmxsr7kwhkkybvxqq9f7p
  text: |-
    Implementation landed (not committed):
    - `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`: names `files`, `shell`, `skills`, `codeContext`, `web`, `git`, `mcp` with each option key and its default, with STE comments. `web.enabled: true` and `git.enabled: true` (the two SwitchableToolOptions bodies). `files.exclude: null` and `shell.storeDirectory: null` so the file decodes to exactly `AgentConfiguration()`. `web.apiKeys: {}`, no secret.
    - `Package.swift`: `resources: [.copy("Resources/builtin.config.yaml")]` on the library target.
    - `Configuration/BuiltinConfigurationFile.swift`: `BuiltinConfigurationFile.url()/root()` over `Bundle.module`; public `BuiltinConfigurationFileError`; `YAMLValue.layered(under:)` (the family merge rule, because the Extras merge is private).
    - `ConfigurationLoader.load()` merges the dotfolder tree over the builtin tree. `sources` still come from the dotfolder document only, so a key that only layer 1 sets reports `builtin`. An internal init takes a `builtinLayer` closure as a test seam.
    - `ToolsConfiguration.optionKeys` is internal now (was private) for the test.
    - Docs: AgentConfiguration, ConfigurationLayerName, ConfigurationLoader, plan.md §2.2 item 1, cli-plan.md §5.10.
    - Tests: new `BuiltinConfigurationFileTests` (resource loads, decodes to `AgentConfiguration()`, names each tool, names each key of `optionKeys`, web/git `enabled: true`, no secret, user `web: false` turns only web off, loader reads layer 1, a dotfolder layer wins); `ConfigShowTests.aUserToolKeyReportsUserAndTheOtherToolKeysBuiltin`; `ConfigInitTests.theWrittenToolsAreTheToolsOfTheBuiltinFile`; `CLIProcessTests.configShowReadsTheBuiltinFileFromTheResourceBundle` (IntegrationTests, spawns the built binary).
    - Binary check: `swift test --package-path IntegrationTests --filter CLIProcessTests` 7/7 pass; the bundle `FoundationModelsACPAgent_FoundationModelsACPAgent.bundle/Contents/Resources/builtin.config.yaml` is beside the binary in `IntegrationTests/.build/out/Products/Debug/`.
    - Discovered: `config path` still prints "(in code, no file)" for the builtin row. New task ^ added for it (depends on this card).
    - The build warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle" comes from the mlx package build graph, not from this change.
  timestamp: 2026-10-08T19:25:39.000826+00:00
- actor: claude-code
  id: 01m4efn189r3h5cga48qde4vq8
  text: |-
    ### implement — changed
    - evidence: `swift test` 814 tests in 88 suites passed (1 known issue, the existing withKnownIssue in HarnessSmokeTests); `swift test --package-path IntegrationTests --filter CLIProcessTests` 7 passed. Files: Package.swift, Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml, Sources/FoundationModelsACPAgent/Configuration/{BuiltinConfigurationFile,ConfigurationLoader,AgentConfiguration,ConfigurationLayerName,ToolSectionCodec}.swift, Tests/FoundationModelsACPAgentTests/{BuiltinConfigurationFileTests,ConfigShowTests,ConfigInitTests}.swift, IntegrationTests/.../CLIProcessTests.swift, plan.md, cli-plan.md
    - next: /review
  timestamp: 2026-10-08T19:25:42.537525+00:00
- actor: claude-code
  id: 01m4efn669x22yzw7p8yj29kv0
  text: The new task for the `config path` builtin row is ^wydftp1 (01M4EFJM9QK6GZEJD0TWYDFTP1).
  timestamp: 2026-10-08T19:25:47.593794+00:00
- actor: claude-code
  id: 01m4eg12exdm8sfcn6cvgz0fgr
  text: |-
    ### test — green
    - evidence: swift test (root) — 814 tests in 88 suites passed, 1 known issue (intentional withKnownIssue in HarnessSmokeTests), 0 failed, 0 skipped. swift test --package-path IntegrationTests --no-parallel — 30 tests in 11 suites passed, 0 failed, 0 skipped. Only warning in both runs: mlx-swift_Cmlx.bundle build-system line from a dependency. No code change made. Package.resolved not moved.
    - next: commit
  timestamp: 2026-10-08T19:32:16.989425+00:00
depends_on:
- 01M4E2A5G4FC38X7WG4P28XJZ6
position_column: doing
position_ordinal: '80'
title: Ship the builtin configuration as a YAML file that names each tool, with each tool on by default
---
## Problem

The builtin configuration (layer 1) is Swift code, not a file. `AgentConfiguration` property defaults and the `init()` of each `*ToolOptions` in `Configuration/ToolSectionCodec.swift` hold the defaults (`ConfigurationLayerName.swift:6`: "the builtin layer is code, not a file"). `ConfigurationYAML` can generate the text of the defaults (`config init`, `config show`, `/config export`), but no YAML file in the repo shows the tools and their defaults. A person must read Swift code to learn which tools exist and which are on.

## Decision

1. Add one YAML file to the library target as a resource: `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`. Declare it in `Package.swift` with `.copy` or `.process`.
2. The file names each tool group under `tools:`: `files`, `shell`, `skills`, `codeContext`, `web`, `git` (from task ^p28xjz6), and `mcp`. Each group that can be off has `enabled: true`. Each option has its default value, and a short comment in ASD-STE100 Simplified Technical English.
3. The loader reads this file as layer 1, under the dotfolder layers. Thus, the file is the builtin configuration.
4. The Swift defaults stay as the decode fallback for a key that a layer does not set. A test makes sure that the file and the code cannot be different:
   - The file decodes to exactly `AgentConfiguration()`.
   - The file names each key of `ToolSectionCodec.optionKeys`. Thus, a new tool group or a new option fails the test until the file names it.
5. `config init` writes the same tool defaults as the file. Keep the existing round-trip rule of `ConfigurationYAML`: the written file reads back to the builtin configuration.
6. A secret (`ConfiguredSecret`, for example a web API key) is never in the file.

## Tests

- The resource loads from the bundle in the unit tests and in the built `acp-agent` binary.
- The file decodes to `AgentConfiguration()`.
- Each key in `ToolSectionCodec.optionKeys` is in the file.
- A user layer that sets `web: false` over the builtin file turns web off, and the other tools stay on.
- `config show --source` names the builtin layer for each key that no layer sets.

## Order

After ^p28xjz6, because the file must name `tools.git`.

#config #tools