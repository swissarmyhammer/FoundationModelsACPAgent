---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7cypaqfgr5gn0376bmvtt3k
  text: |-
    Research + implementation notes:
    - The only always-on feed is `ToolCatalog.endpointToolNames` -> `alwaysOnToolNames`, read by `SessionToolSelection.init` (root + `RegistrySelection.applied(to:)`, which the run catalog also uses via `AgentsComposition.runRegistrySelection`) and by `SessionToolSelection.templateGroups` (root and run template values). Removing `filesGroupName` from `endpointToolNames` changes all four paths at once; no other name needed to move.
    - Nothing else must keep `files` on: `SessionSurface.filesReadVerb` is taken from `built.registry.tools[files.read]` (unfiltered) and `replacing(tools:agents:)` carries it over, so resource links keep working (guard test `disallowedFilesKeepsTheResourceLinks`). `applied(to:)` keeps the GraphQL endpoints of the full registry; `files` has none of its own.
    - searchTools shares one RegistryHolder with runCode. Calling it on the stub harness session fails (stub flash answers non-JSON to the selection tier), so the searchTools tests build a surface with `AgentsToolTests.makeContext(script:)` whose flash answers `{"ids":["files.read"]}`, then `applying(agent:)`.
    - RED: 12 tests failed before the change (selection, template values root + run, root runCode, searchTools, run and child run); default-keeps-files tests and the resource-link guard passed as expected. GREEN: SessionAgentToolsTests + RunToolSelectionTests 65/65.
    - Follow-up outside this repo: the ACPA-1 spec (TestudoApp/features/packages/foundationmodels-acpagent.md, D90 (c)) still says runCode gives files; skills that gate on `tools.files.enabled` now see false for agents with `tools:` lists that omit files.
  timestamp: 2026-11-14T11:57:10.255571+00:00
- actor: claude-code
  id: 01m7cyqtw4htkywzh1bf6wrwde
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift, Tests/FoundationModelsACPAgentTests/RunToolSelectionTests.swift. `swift test`: 2085 tests in 223 suites passed, 0 failures, 1 known issue (pre-existing `withKnownIssue` in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps). Only warning is the SwiftPM build-graph line "missing creator for mutated node ... mlx-swift_Cmlx.bundle", unrelated to this change.
    - next: /review
  timestamp: 2026-11-14T11:57:59.556196+00:00
position_column: doing
position_ordinal: '8380'
title: A session agent can deny the files group
---
## What
Decision (user, 2026-11-14): the `files` Multitool group is deniable for an agent, like `shell`, `web` and `git`. This reverses the earlier reading of D90 (c) on ^b013mv9 that "`runCode` always gives `files`". `files` has no GraphQL endpoint of its own (only `snapshots` and `sessions` do in Multitool), so it is not an endpoint tool.

Today `ToolCatalog.filesGroupName` is in `ToolCatalog.endpointToolNames` (Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift), which feeds `alwaysOnToolNames`, read by `SessionToolSelection.init` and `SessionToolSelection.templateGroups`. So `disallowedTools: [files]` keeps `files` in the root `runCode` (pinned by `disallowedFilesStaysInTheRootRunCode`, commit 06f017d).

## Work
1. Remove `files` from the always-on set. Keep every name that truly must stay always-on.
2. Resource links (`SessionSurface.filesReadVerb`, built from the unfiltered registry) and the GraphQL endpoints (`RegistrySelection.applied(to:)` keeps those of the full registry) still work with `files` denied.
3. Update the doc comments that state the old rule.

## Acceptance Criteria
- [ ] A session agent with `disallowedTools: [files]` has no `files` in the root `runCode` or `searchTools`.
- [ ] A session agent with `tools: [agents, kanban]` has no `files` group.
- [ ] A session agent with no `tools:` key and no deny still has `files`.
- [ ] The template value `tools.files.enabled` is false when `files` is denied.
- [ ] A resource link still resolves when `files` is denied.
- [ ] A child agent run with `disallowedTools: [files]` has no `files`; one without has `files`.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift`: `disallowedFilesStaysInTheRootRunCode`, `disallowedFilesKeepsTheFilesTemplateValueOn`, `toolsWebGivesTheModelFilesAndWebOnly`, `alwaysOnNames` follow the new rule.
- [ ] Child agent test in `RunToolSelectionTests.swift`.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.