---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5d0w3gpejrm041pvxb7tf6w
  text: |-
    MT-9 host-tool part is pushed: FoundationModelsMultitool main b2a22d99010231329d6208574179c2b0e694065f (from the Multitool session, 2026-10-20).
    - API: `MultiTool.Builder.withOperationTool(noun: String, tool: any OperationDescribing) -> Self` (discardable). Use `builder.withOperationTool(noun: "settings", tool: settingsTool)`.
    - Each operation becomes one verb `tools.settings.<verb>`. The verb is the camelCase form of the op string (`get setting` gives `tools.settings.getSetting`).
    - The noun is owned: a second registration under `settings` makes `buildRegistry()` fail.
    - The calls go through the same `runCode` path as the built-in verbs, so the risk check sees them.
    - Thus `SettingsTool` (card ^cj9s5j0) must conform to `OperationDescribing` too. Update the Multitool dependency to this sha or later.
  timestamp: 2026-10-20T16:03:52.982583+00:00
- actor: wballard
  id: 01m5d0we9m65dk1qemm6pmsnmf
  text: 'Update from the TestudoApp session (2026-10-20): the risk check (MT-1 of Multitool) has no code yet. Thus the criterion "The risk check sees a settings mutation" cannot be tested now. For this card, test that a `tools.settings` call goes through the registry and the `runCode` path as a built-in verb does. The risk check sees the calls when MT-1 comes. A duplicate noun gives `.duplicateNoun` from `buildRegistry()` (or `.duplicateName` when a verb path collides).'
  timestamp: 2026-10-20T16:04:04.020727+00:00
- actor: claude-code
  id: 01m5dkckv92tgvnmctxmjwbdbs
  text: |-
    Research (implement step):
    - Multitool d618aa8 has `withOperationTool(noun:tool:)`; it wraps the tool in `OperationToolCapability`, so the verb is `tools.settings.querySettings` and the call uses the same registry and `runCode` path as a built-in verb.
    - `SettingsTool(store:)` does not know a cwd. Each `setting`, `set` and `clear` field of the schema has a required `cwd: String!` argument. Thus the tool cannot "know the cwd of the session" without a change.
    - Plan: `SettingsTool(store:sessionDirectory:)`. The `cwd` argument becomes optional in the schema. The resolver gets the cwd from the call context: a call with no `cwd` uses the session folder of the tool; the endpoint (no session folder) refuses a call with no `cwd` (new code `MISSING_CWD`). A session tool refuses a `cwd` that is not its session folder (new code `OTHER_SESSION_CWD`), so a session-level write always goes to the cwd of that session.
    - `CatalogContext` gets `settingsStore: SettingsStore?` (as `snapshotStore`). `composeSession(from:...)` gives `settingsStore`. `ToolCatalog.makeRegistry` registers the tool with `withOperationTool(noun: "settings", ...)`. `makeStandaloneTools` does not change.
    - No `SessionComposer` exists; both session start paths go through `composeSession(from:)` and `makeRegistry`.
  timestamp: 2026-10-20T21:27:28.361806+00:00
- actor: claude-code
  id: 01m5dksngh6s8qbwrkaxg5b1b6
  text: |-
    Implementation landed (not committed).
    - `SettingsTool(store:sessionDirectory:)`: a new optional session folder. `ToolCatalog.makeRegistry` registers `SettingsTool(store: context.settingsStore, sessionDirectory: context.workingDirectory)` with `withOperationTool(noun: "settings", ...)`. `CatalogContext.settingsStore` is new; `composeSession(from:...)` gives `settingsStore`. `makeStandaloneTools` does not change.
    - The `cwd` argument of `setting`, `set` and `clear` is now optional (golden `Tests/Fixtures/settings.graphql` updated). `SettingsGraphContext.workingDirectory(given:)` resolves it: the endpoint with no `cwd` gives `MISSING_CWD`; a session tool with no `cwd` uses its folder; a session tool with a `cwd` of another folder gives `NOT_SESSION_CWD` (compared after symlink resolution, so `/private/var` and `/var` match). Thus a SESSION write from the tool always goes to the cwd of that session.
    - Discovery: a call through the registry returns the GraphQL response as a parsed object, not as JSON text (the verb wraps the string). In `runCode` the snippet gets an object too; key order of `JSON.stringify` is not the sorted order of the endpoint.
    - Risk check (MT-1) has no code; the session test proves the `runCode` path, as the comment of 2026-10-20 says. That criterion stays open until MT-1.
    - README tools table has a `settings` row.

    ### implement — changed
    - evidence: `swift test` 1157 tests in 125 suites passed (1 known issue, pre-existing `withKnownIssue` in HarnessSmokeTests); new tests: SettingsToolTests (4), SettingsGraphTests (1), ToolCatalogTests (4), SettingsToolSessionTests (1). Files: SettingsTool.swift, SettingsGraph.swift, SettingsGraphSchema.swift, SettingsGraphError.swift, CatalogContext.swift, ToolCatalog.swift, SessionSetup.swift, README.md, Tests/Fixtures/settings.graphql, SettingsGraphFixture.swift, SettingsToolTests.swift, SettingsGraphTests.swift, ToolCatalogTests.swift, SettingsToolSessionTests.swift (new).
    - next: /review
  timestamp: 2026-10-20T21:34:36.049551+00:00
- actor: claude-code
  id: 01m5dkxt82aq6btyrezbk6cfs6
  text: |-
    ### test — green
    - evidence: touched the 14 changed sources, then swift test: 1157 tests in 125 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted). swift build --build-tests --package-path IntegrationTests: Build complete. Filter SettingsGraphTests, SettingsToolTests, SettingsToolSessionTests, ToolCatalogTests run 3 times: 65 tests in 4 suites passed each time. Compiler warnings: only the accepted mlx-swift_Cmlx "missing creator for mutated node" warning. The "warning" lines in the test output are runtime log lines from tests of warning paths.
    - next: review
  timestamp: 2026-10-20T21:36:51.970226+00:00
depends_on:
- 01M5CZ3SZ6Y0PQDSFMGCJ9S5J0
position_column: doing
position_ordinal: '80'
title: 'ACPA-17: the session gives SettingsTool to Multitool under the noun settings (MT-9)'
---
## What
ACPA-17 and D100(f): the session composition makes one `SettingsTool` for each session and gives it only to the Multitool registry, under the noun `settings`. The agent calls `tools.settings.*` in `runCode`, and the risk check sees each call (D76). It is not a top-level tool of the session.

**Blocked outside this board:** MT-9 of FoundationModelsMultitool (a host tool under a noun) must be done first. Now Multitool has only `withCapability(_:)` (`../FoundationModelsMultitool/Sources/FoundationModelsMultitool/Surface/MultiToolBuilder.swift:217`). Do not change Multitool from this board.

Now there is no `SessionComposer`. The session is composed in `RoutedACPAgent.composeSession(from:workingDirectory:additionalRoots:clientMCPServers:)` (`SessionSetup.swift:870-908`), and the registry in `ToolCatalog.makeRegistry(context:)` (`ToolCatalog.swift:391-465`). `ToolCatalog.makeStandaloneTools` (lines 355-357) gives the top-level tools.

Do this after MT-9:
- In `makeRegistry`, register the `SettingsTool` of the session with the MT-9 API under the noun `settings`. The tool knows the cwd of the session, so a query gives the merged value for that cwd, and a `session` level write goes to that cwd.
- Do not add it to `makeStandaloneTools`.
- If the `SessionComposer` of the design exists then, put the code there, so a session that a client starts and a session that the launcher starts have the same tools.
- The mutations are writes for the risk check (the same class as a file write).

## Acceptance Criteria
- [x] `tools.settings` is in `searchTools` and works in `runCode`.
- [x] `settings` is not a top-level tool of the session.
- [ ] The risk check sees a `settings` mutation. (MT-1 has no code yet. Per the comment of 2026-10-20, the test proves that a `tools.settings` call goes through the registry and the `runCode` path as a built-in verb does.)
- [x] A session level write from the tool goes to the cwd of that session.

## Tests
- [x] A session test that runs `runCode` with a `tools.settings` query and a mutation, then reads the `config.yaml` of the cwd.
- [x] A test that the top-level tool list has no `settings`.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17