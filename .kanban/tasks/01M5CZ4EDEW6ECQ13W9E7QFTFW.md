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
depends_on:
- 01M5CZ3SZ6Y0PQDSFMGCJ9S5J0
position_column: todo
position_ordinal: 8c80
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
- [ ] `tools.settings` is in `searchTools` and works in `runCode`.
- [ ] `settings` is not a top-level tool of the session.
- [ ] The risk check sees a `settings` mutation.
- [ ] A session level write from the tool goes to the cwd of that session.

## Tests
- [ ] A session test that runs `runCode` with a `tools.settings` query and a mutation, then reads the `config.yaml` of the cwd.
- [ ] A test that the top-level tool list has no `settings`.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17