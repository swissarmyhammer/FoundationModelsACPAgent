---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7306sntbz97v91xsbvg37by
  text: 'Decision from testudoapp-75 (2026-11-10): the key is `mode` in `_meta.sah` of the initialize result. The values are "open" and "sandboxed", which are the raw values of ToolMode. TestudoApp ^3czzrg4 waits on this task. Send the commit to testudoapp-75 when you push it.'
  timestamp: 2026-11-10T15:11:14.106864+00:00
- actor: claude-code
  id: 01m73080t5t2mnckwrte0bzawp
  text: |-
    Facts from testudoapp-75 (2026-11-10):
    1. SK-7a (^3npmrkb on the Skills board) adds a REQUIRED `mode` parameter to `SkillsToolContext` and `SkillsRegistry`. Pass the mode to both (ToolCatalog.makeSkillsSource and the skills tool). When SK-7a is pushed, this package does not build until it passes the mode. Agree the time of the dependency bump with session `foundationmodelsskills-f7`.
    2. In `sandboxed` mode, do not start a stdio MCP server process at all. Filter the stdio entries before `MCPComposition.connectServers`, not only in composeRoster, because Multitool gets only servers that are already connected. Multitool (session `foundationmodelsmultitool-2a`) adds a guard on `StdioServerProcess` and tells us before an API change. Add a test: in `sandboxed` mode no `StdioServerProcess` starts.
    3. Skills layers: no change is necessary. `ToolCatalog.makeSkillsSource` uses `SkillsRegistry(stack:)`, not `SkillsRegistry(roots:)`. `SettingsFolders` labels `<synced>/_skills/` as `.user` and `<cwd>/.skills/` as `.project`, and `SettingsFoldersTests.swift` (~198) tests this. Keep `SkillsRegistry(stack:)` when you add the mode.
  timestamp: 2026-11-10T15:11:54.181464+00:00
- actor: claude-code
  id: 01m732b1eya3pecpcmx2nd7pf6
  text: |-
    EXTRAS-12 is pushed (FoundationModelsExtras main, feature commit af13e80, head 4254281). API in the core target FoundationModelsExtras, Sources/FoundationModelsExtras/Hosting/ToolMode.swift:
    - `public enum ToolMode: String, Sendable, Codable, CaseIterable { case open, sandboxed }`. It encodes as a plain string, so put it in `_meta.sah.mode` directly.
    - `public struct SandboxProbe`: `.live`, `.fixed(Bool)` for tests, `init(isSandboxed:)`.
    - `public enum ToolModeError: Error { case openModeInSandbox }`.
    - `mode.validate(probe: SandboxProbe = .live) throws(ToolModeError)`: call it in `compose` before any tool is registered. Let `compose` take a `SandboxProbe` (default `.live`) so tests can use `.fixed`. Add a test: `open` mode with `.fixed(true)` makes `compose` throw `openModeInSandbox`.
    Docs: FoundationModelsExtras docs/REFERENCE.md ("Tool modes: ToolMode") and docs/GUIDE.md.
    This task still waits for MT-15 (mode part) and SK-7a.
  timestamp: 2026-11-10T15:48:30.302859+00:00
- actor: claude-code
  id: 01m7332kb10cxeg34dt6qr9900
  text: 'MT-15 part 1 is pushed (FoundationModelsMultitool main d5090dea). API: `MultiTool.Builder.init(mode: ToolMode = .open, sandboxProbe: SandboxProbe = .live)`. `buildRegistry()` and `build()` call `mode.validate(probe:)` first. In `sandboxed` mode, a builder with `withShell` throws `MultiToolBuilderError` kind `.notAvailable(mode: .sandboxed)`, name "shell". For this task: give `MultiTool.Builder(mode:sandboxProbe:)` in `ToolCatalog.makeRegistry`, and do not call `withShell` in `sandboxed` mode. Multitool ^t8ye77q (the stdio MCP guard) comes next. Multitool will tell us before it pushes an API change to `StdioServerProcess` or `withMCP`. This task still waits for SK-7a. The work can start without ^t8ye77q, because this task filters the stdio entries before `MCPComposition.connectServers`.'
  timestamp: 2026-11-10T16:01:22.273119+00:00
- actor: claude-code
  id: 01m7333adkn7g8kz25akz7jnn5
  text: 'Multitool ^9amym5ns removes the `= .open` default of `MultiTool.Builder(mode:)`. It waits until this task is on origin/main. Thus every `MultiTool.Builder(` call in this package must give `mode:` explicitly, in Sources and in Tests: `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:464`, `Tests/.../SettingsToolTests.swift:294`, `ShellSessionOwnerTests.swift:57`, `PromptContentTests.swift:42`, `MCPCompositionTests.swift:270`. Add an acceptance check: `grep -rn "MultiTool.Builder()" Sources Tests` finds nothing. When this task is pushed, send the commit to foundationmodelsmultitool-2a and to testudoapp-75.'
  timestamp: 2026-11-10T16:01:45.907882+00:00
- actor: claude-code
  id: 01m7333f7m0xc8yv59q99ac89q
  text: 'Correction: the short id of the Multitool task that removes the builder mode default is ^amym5ns, not ^9amym5ns.'
  timestamp: 2026-11-10T16:01:50.836999+00:00
depends_on:
- 01M73026P78T3QV61E24Z44FHR
position_column: todo
position_ordinal: '8580'
title: 'ACPA-19b: The host ToolMode in ComposedAgent and RoutedACPAgent; sandboxed mode removes child-process tools and CodeContext'
---
## What
Spec: ACPA-19 (TestudoApp/features/packages/foundationmodels-acpagent.md). Decisions D128 (d, h), D131.

External dependencies (not on this board; do not start until they are pushed): EXTRAS-12 `ToolMode` (FoundationModelsExtras, session `foundationmodelsextras-de`), MT-15 mode part (FoundationModelsMultitool, session `foundationmodelsmultitool-2a`), SK-7 (FoundationModelsSkills).

1. `Sources/FoundationModelsACPAgent/ComposedAgent.swift` `compose(...)` and the `RoutedACPAgent` init (`RoutedACPAgent.swift` ~454): add `mode: ToolMode`. No default value for the library API, so a host must select one.
2. Pass the mode to Multitool (MT-15) and to Skills (SK-7) in `Tools/ToolCatalog.swift` and `ToolCatalog.makeSkillsSource`.
3. In `sandboxed` mode:
   - no shell (`ToolCatalog` does not call `withShell`);
   - no stdio MCP server (`Tools/MCPComposition.swift` composeRoster drops the stdio entries, and records one refusal for each);
   - no skill scripts (SK-7);
   - no CodeContext: do not open a `CodeContextLease` and do not mount the `code_context` group (`Tools/CodeContextLease.swift`, `ToolCatalog.codeContextGroupName`) (D131).
4. `Sources/FoundationModelsACPAgent/Agent/Initialization.swift` `advertisedSAHMeta()`: add the mode to `_meta.sah` of the `initialize` result (for example `_meta.sah.mode: "open" | "sandboxed"`). Agree the key with `testudoapp-75` (APP-19) before the commit.
5. `Sources/acp-agent/AgentComposition.swift`: the CLI always gives `.open`.
6. The data folders (D128 h): confirm that `compose` takes the hooks data folder, the model cache (`modelCacheDirectory`, done in `596d68c`) and the skills marketplace cache from the host. Add a parameter for each one that is missing.

## Acceptance Criteria
- [ ] An agent composed in `sandboxed` mode has no session with the shell, a stdio MCP server, a skill script or a code context tool.
- [ ] In `sandboxed` mode no `CodeContext` starts.
- [ ] An agent composed in `open` mode has the same tools as today.
- [ ] The `initialize` result has the mode in `_meta.sah`.
- [ ] The `acp-agent` CLI composes in `open` mode.
- [ ] The host can give the hooks data, model cache and marketplace cache folders.

## Tests
- [ ] New `Tests/FoundationModelsACPAgentTests/ToolModeTests.swift`: compose in `sandboxed` mode with a config that has a shell, a stdio MCP server, a skill with a script and `codeContext:` on; confirm none is in the session surface and no lease opens. Compose in `open` mode and confirm all are there.
- [ ] `Tests/FoundationModelsACPAgentTests/InitializationTests.swift` (or the current one): the `initialize` result `_meta.sah` has the mode, for both values.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1