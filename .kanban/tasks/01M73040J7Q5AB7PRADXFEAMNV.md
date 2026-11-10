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
- actor: claude-code
  id: 01m733f7a346f21j3179c41kq0
  text: 'FYI from testudoapp-75: FoundationModelsSkills c04d4cc (SK-6a, head 0c615bd) changes an API. `SkillsRegistry.onReload` is now a non-optional `AsyncStream`. `SkillsToolAssembly` always makes the notice follower, so `commandUpdates` stays optional but is never nil. Check of this package (2026-11-10): no source uses `onReload`. `CommandRegistry.swift:336-337` reads `registry.commandUpdates` with `guard let`. It still compiles, but the `nil` branch is dead code. At the Skills bump, remove the dead branch, and change the doc text at `ToolCatalog.swift:678` and `SessionSetup.swift:1062` that says "`watch: true` makes `commandUpdates` non-nil".'
  timestamp: 2026-11-10T16:08:15.939238+00:00
- actor: claude-code
  id: 01m73594tqdt53ymwc00r80r9p
  text: 'SCOPE CHANGE (2026-11-10, agreed with testudoapp-75): this task does NOT wait for SK-7a now. Do the mode part only: the mode and `SandboxProbe` in `compose` and the `RoutedACPAgent` init (with `mode.validate(probe:)` before any tool registers), `mode:` in every `MultiTool.Builder` call (Sources and Tests), no shell in `sandboxed` mode, no stdio MCP server before `MCPComposition.connectServers`, no CodeContext lease or tools, `_meta.sah.mode` in the initialize result, the CLI on `.open`, and the data folders. The skills part (step 3 "no skill scripts", the SK-7a mode for `SkillsToolContext` and `SkillsRegistry`, and the SK-6a `commandUpdates` cleanup) moves to the new follow-up task ACPA-19d. Leave the skill script criterion and test to that task. Keep the mode where ACPA-19d can read it. When pushed, send the commit to foundationmodelsmultitool-2a (for ^amym5ns) and to testudoapp-75.'
  timestamp: 2026-11-10T16:39:53.943591+00:00
- actor: claude-code
  id: 01m735msjdptmrex1pwnssj983
  text: |-
    Research (implement step, mode part only):
    - `swift package update` (root and IntegrationTests): Extras 4254281 (has af13e80), Multitool e079c44 (has d5090dea and "c86908b1 remove Seatbelt"), Skills ac4250d (SK-6a and SK-6b, no SK-7a). The root package builds. One new warning came from SK-6a: `InstructionsAssemblerTests.swift` had `try #require(registry.onReload)`, and `onReload` is not optional now. I removed the `#require`. This is not the `commandUpdates` cleanup of ^bwgmkc0.
    - `SAH.InitializeMeta` (FoundationModelsACP) has no `mode` field. This package cannot edit that repository. Thus the agent writes `mode` into the `_meta.sah` object itself.
    - Data folders (D128 h): `compose` takes `AgentHome`. It has `hooksDirectory`, `modelCacheDirectory` and `skillsMarketplaceCacheDirectory`, and `makeCustom(synced:local:projects:)` lets the host set the root of each. `compose` uses `home.hooksDirectory` for the hooks and `home.modelCacheDirectory` for the router, and the session reads `home.skillsMarketplaceCacheDirectory`. No parameter is missing.
    - The mode flows: `compose(mode:sandboxProbe:)` -> `RoutedACPAgent(mode:sandboxProbe:)` -> `CatalogContext.toolMode` and `CatalogContext.sandboxProbe` -> `ToolCatalog` and `MCPComposition`. ACPA-19d (^bwgmkc0) can read `context.toolMode` in `makeSkillsSource`.
    - Outside the scope, for ^bwgmkc0: `ToolCatalog.skillsTemplateContext` gives `tools.shell.enabled` and `tools.codeContext.enabled` from the configuration only. In `sandboxed` mode these are true when the configuration has them on, but the session has no such tool.
    - The sibling FoundationModelsACPClient (IntegrationTests/LiveAgentServer) calls `RoutedACPAgent(...)` with no `mode:`. It will not build after this change until it gives the mode.
  timestamp: 2026-11-10T16:46:15.629486+00:00
- actor: claude-code
  id: 01m7366acvbx5kftd9entjtc2r
  text: |-
    Implementation landed (mode part only; the skills part stays with ^bwgmkc0).
    - Pins after `swift package update` (root and IntegrationTests): Extras 4254281 (has af13e80), Multitool 4f0c664c (has d5090dea and ^t8ye77q), Skills ac4250d (no SK-7a), Agents 40dfd05 (NOT e539c27, thus no `DefaultAgentInstructions` rename was necessary).
    - `ComposedAgent.compose(...mode:sandboxProbe:...)` and `RoutedACPAgent.init(...mode:sandboxProbe:...)`: `mode` has no default; `sandboxProbe` defaults to `.live`. Each calls `mode.validate(probe:)` first. `RoutedACPAgent.toolMode` is public.
    - `CatalogContext` has `toolMode` (init label `mode:`, required) and `sandboxProbe`. ^bwgmkc0 reads `context.toolMode`.
    - `ToolCatalog.makeRegistry`: `MultiTool.Builder(mode:sandboxProbe:)`. `composeShell` and `composeCodeContext` do nothing in `sandboxed` (no shell store lease, no CodeContext lease, no `code_context` group).
    - `MCPComposition.composeRoster(mode:section:clientServers:)` and `connectServers(mode:...)`: in `sandboxed` each stdio entry (config and client) is removed before the connect step, with one `Refusal.stdioInSandboxedMode(serverName:)` and one `.failed(reason: .stdioInSandboxedMode)` outcome for each. Second guard: `StdioServerProcess(... mode:)` gets the mode; its `.notAvailable` error maps to the same reason.
    - `_meta.sah.mode` = "open" | "sandboxed": `AdvertisedSAHObject` in Initialization.swift encodes the `SAH.InitializeMeta` members plus `mode` into one object (the wire package has no `mode` field).
    - CLI `AgentComposition.compose` gives `.open`.
    - Data folders: no change; `AgentHome` already carries the hooks, model cache and marketplace cache folders (see the research comment).
    - Every `MultiTool.Builder(` call in Sources and Tests gives `mode:`. `grep -rn "MultiTool.Builder()" Sources Tests` finds nothing.
    - Also: removed a redundant `try #require(registry.onReload)` in InstructionsAssemblerTests (a warning from the SK-6a pin).
    - Cross-repository note: FoundationModelsACPClient IntegrationTests/LiveAgentServer calls `RoutedACPAgent(...)` with no `mode:`; it must add `mode: .open` when it takes this commit.
    - New task added: the static `advertisedCapabilities` still advertise `mcp.stdio` in `sandboxed` mode.

    ### implement — changed
    - evidence: 37 files (new Tests/FoundationModelsACPAgentTests/ToolModeTests.swift with 18 tests; InitializationTests +2 cases; AgentCompositionTests +1). `swift test`: 1863 tests in 209 suites passed (1 known issue, the existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. `swift build --build-tests --package-path IntegrationTests`: Build complete.
    - next: review
  timestamp: 2026-11-10T16:55:49.915154+00:00
- actor: claude-code
  id: 01m736ftewd910mk25wrhtr0pw
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (d3e0463): 3 findings (3 confirmed, 2 refuted) — Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:526, Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:198, Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:265. No finding is about the skills part that moved to ^bwgmkc0.
    - next: implement the 3 findings in the "Review Findings (2026-11-10 10:56)" section, then review again.
  timestamp: 2026-11-10T17:01:01.276133+00:00
- actor: claude-code
  id: 01m736s53vccz61czfgyxscfap
  text: |-
    Picked up the 3 findings of "Review Findings (2026-11-10 10:56)".
    - Finding 1: the mode test is in two guards of ToolCatalog.swift only (composeShell, composeCodeContext). The stdio filter is not in ToolCatalog.swift: ToolCatalog gives `context.toolMode` to `MCPComposition.connectServers`, and MCPComposition has one `switch mode` (no second copy). New helper `ToolCatalog.childProcessOptions(of:in:)` holds the rule; both guards call it.
    - `CatalogRegistryFixture.makeContext(workingDirectory:configuration:mode:)` is new; `makeBuiltRegistry` uses it. The helper tests use it.
  timestamp: 2026-11-10T17:06:07.099558+00:00
- actor: claude-code
  id: 01m7387vt2ngtpjrrxazqjd4pe
  text: |-
    Work on the 3 findings is complete. All 3 are now `- [x]`.
    - Finding 1: the new `ToolCatalog.childProcessOptions(of:in:)` holds the mode rule. `composeShell` and `composeCodeContext` call it. No other copy of the rule is in ToolCatalog.swift: the stdio filter is in MCPComposition.swift, and it uses one `switch mode`. New tests: the sandboxed mode gives nil, the open mode gives the options of an enabled section, and the open mode gives nil for a disabled section.
    - Finding 2: new `theOpenModeStartsTheStdioServerProcess` uses the same marker script, and the marker file is there after the build.
    - Finding 3: new `theAgentAcceptsTheOpenModeOutsideASandbox` uses `mode: .open` with `.fixed(false)` and expects `agent.toolMode == .open`.
    - Approach that did not work: the old marker script ran `touch` and then exited. In the open mode the connect of a config stdio server waits for `.ready`, and it did not stop when the process exited. The test run stopped for more than 15 minutes. Correction: the script now runs `touch` and then `exec` of the `mcp-test-server` executable, so the server connects in the open mode. The sandboxed test uses the same script. There is a latent problem here: a config stdio server that exits before it answers can make `session/new` wait for a long time. I did not change this in the scope of this task.
    - Pins: no `swift package update`. Skills stays at ac4250d (the coordinator said this; the SK-7a bump belongs to ^bwgmkc0).
    - The `sah tool kanban task update` CLI did not complete in 120 s while the MCP server was running. Use the MCP `update task` op.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/ToolModeTests.swift, Tests/FoundationModelsACPAgentTests/Support/CatalogRegistryFixture.swift. `swift test --filter ToolModeTests`: 22 tests passed. Full `swift test`: 1868 tests in 209 suites passed (1 known issue, the existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. The only "warning:" line is the build-system note "missing creator for mutated node" on the mlx bundle.
    - next: review
  timestamp: 2026-11-10T17:31:37.666297+00:00
depends_on:
- 01M73026P78T3QV61E24Z44FHR
position_column: doing
position_ordinal: '8180'
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

## Review Findings (2026-11-10 10:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 36 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:526` `duplication/duplication` — The sandbox gate `context.toolMode == .open` is written out twice, once in `composeShell` and once in `composeCodeContext`, and each sits in a near-verbatim `guard ..., case .enabled(let options) = ... else { return nil }` block. The two blocks differ only by the config section (`shell` or `codeContext`). The mode check is the rule that keeps a sandboxed process from starting child processes. If a later edit changes one gate and not the other, the sandbox guarantee breaks silently. One helper that takes the section and applies the mode check would hold the rule in one place.
- [x] `Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:198` `completeness/inverse-operation-coverage` — The sandboxed no-process test asserts that the marker file does not exist, but no test in this file shows that the same marker script creates the marker when the server is allowed. The negative assertion would also pass if the marker script never ran for any reason, so it does not prove that sandboxed mode refused the start. Add a positive control: build the same marker-script configuration in `.open` mode and assert that the marker file exists after `buildRegistry`, then keep the sandboxed assertion that it does not exist. This shows the negative assertion can fail.
- [x] `Tests/FoundationModelsACPAgentTests/ToolModeTests.swift:265` `completeness/inverse-operation-coverage` — The agent-level guard is tested only in the refusal direction. No test builds an open-mode agent or composition with a probe that reports no sandbox and checks that it is accepted. A guard that wrongly refuses open mode outside a sandbox would still pass every test in this suite. Add one case that composes or makes a stub agent with `mode: .open` and `sandboxProbe: .fixed(false)`, and asserts that it succeeds and that `agent.toolMode == .open`.
