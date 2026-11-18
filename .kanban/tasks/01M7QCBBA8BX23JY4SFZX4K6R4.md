---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qccs19vfx4z1qrzskqd3jq
  text: 'Dependency update from the TestudoApp session (2026-11-18): Multitool ships `BuiltinSkills.directory` and the `sessions` SKILL.md resource as a separate task. That task comes before its D199 work and does not depend on Extras. Multitool sends the commit sha when it lands. Then this task can start. It does not wait for Extras or the D199 Router work.'
  timestamp: 2026-11-18T13:09:01.609884+00:00
- actor: claude-code
  id: 01m7qdpa4a1s7jzqxdrnstt66m
  text: 'Dependency available (2026-11-18): FoundationModelsMultitool commit e8e0e3469f908f7f113f974892aab76d1afb89b8 (main head 0201e78d, pushed). API: `public enum BuiltinSkills { public static var directory: URL }`, the `skills` folder in the bundle of the library. Each child folder is one skill; today it has `sessions/SKILL.md`. Run `swift package update FoundationModelsMultitool` to move `Package.resolved`. Multitool task ^0xrgvnk changes the skill text later; the folder and the API do not change. This task can start.'
  timestamp: 2026-11-18T13:31:42.602977+00:00
- actor: claude-code
  id: 01m7qe2grs3jk2gjqpe39fb6kc
  text: |-
    Research (2026-11-18):
    - `swift package update FoundationModelsMultitool` moved Multitool to 0201e78d. Package.resolved is in .gitignore, thus the change is local only and no file of the repo changes for it. No other package was changed.
    - The `acp-agent` CLI makes its stacks through `SettingsFolders` (`AgentComposition.makeConfigurationLoader`, `ComposedAgent`). Thus the change in `SettingsFolders.stack(for:workingDirectory:)` gives the CLI the same built-in layer. No CLI code changes.
    - The endpoint and the skills tool read the layer from `SkillsRegistry.records()` (`SkillRecord.layer`), and `SkillsGraphLayer` already maps `.defaults` to `DEFAULTS`. `SkillWriteLayer` has no case for `.defaults`, and the default write layer is `.user` (D175). Thus no change in Skills.
    - Two existing tests (`withARootTheLayersAreTheRootAndTheProjectDotfolder`, `withNoRootEachKindKeepsTheOldLayerList`) expect no defaults layer for `.skills`. They change: `KindCase` gets `builtinDefaults`.
  timestamp: 2026-11-18T13:38:22.617884+00:00
- actor: claude-code
  id: 01m7qes53ycgyfdtn5am5q3gk3
  text: |-
    Implementation landed (2026-11-18).

    Correction to the research comment: the build needed more package changes. HEAD c6a2d28 did not compile with the old local Package.resolved (`KVCacheQuantization` not found). Router `main` e089db5 and Extras `main` 1c69b4f do not compile with HEAD either (`StubModelLoader` does not conform to `ModelLoader`: Router 63e4c70c added `kvCache:` to `loadLLM`). `swift package resolve --revision` refuses a revision for a `main` branch requirement, thus I pinned by hand in the local, gitignored Package.resolved: Router 68930ca0, Extras ea9ecc6, mlx-swift-lm `stable` 8e3daa7, Multitool 0201e78d. New task ^t6mzkb3 adopts Router `main`.

    Changes:
    - `SettingsFolders.stack(for:workingDirectory:)` gives `defaultsDirectory: Self.builtinDirectory(of: kind)`. `builtinDirectory(of:)` gives `BuiltinSkills.directory` for `.skills` and `nil` for each other kind. `SKILLS_DEFAULTS_DIR` still wins (DotfolderStack reads it first).
    - No change to the CLI code, the preload code, `InstructionsAssembler`, or Skills. The CLI reads `SettingsFolders` through `AgentComposition.makeConfigurationLoader` and `ComposedAgent`.
    - Tests: `SettingsFoldersTests` (built-in layer with and without a root, `SKILLS_DEFAULTS_DIR` override, no defaults layer for other kinds, `sessions` from `defaults` with no marketplace, a user copy replaces it, `add skill sessions` writes `<root>/_skills/sessions/SKILL.md` with layer `user`) and `AgentCompositionTests.theSkillsStackOfTheCLIGivesTheBuiltinSkill`. Each new test failed before the change.
    - `withARootNoLayerIsInTheConfigHomeOrTheHomeDirectory` now does not examine the built-in layer: the bundle of Multitool is in `.build/` of the checkout, which can be in the home directory.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Configuration/SettingsFolders.swift, Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift; `swift build --build-tests` Build complete!; `swift test --skip-build` 2232 tests in 237 suites passed (1 known issue, HarnessSmokeTests, before this change).
    - next: /review
  timestamp: 2026-11-18T13:50:44.350694+00:00
- actor: claude-code
  id: 01m7qezce1jdj2rqvzge03p60r
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (f6c723d): 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift:281 (reuse/reuse)
    - next: Do the open item in "Review Findings (2026-11-18 07:51)". Then do the review again. The task stays in review.
  timestamp: 2026-11-18T13:54:08.449471+00:00
- actor: claude-code
  id: 01m7qezpz4re9mmf7wr5vyw81y
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files
    - test: green — swift test --skip-build, 2232 tests in 237 suites passed (run by the implement step on the same tree)
    - commit: f6c723d
    - review: findings — Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift:281
  timestamp: 2026-11-18T13:54:19.236142+00:00
- actor: claude-code
  id: 01m7qf3cyemrvd1819y47w1f7y
  text: |-
    Review finding done (2026-11-18). The body of `lowestSkillsLayer` is now `try #require(Self.layerList(of: settingsFolders.stack(for: .skills, workingDirectory: workingDirectory)).first)`. The `#require` stays. The same cause was also in `theLowestSkillsLayerIsTheBuiltinSkillsOfMultitool`: its expected value built the `<source>:<root path>` string again. Now it makes a `DotfolderStack` with one `.defaults` layer at `BuiltinSkills.directory` and compares `[lowest]` with `layerList(of:)` of that stack. The file has no other copy of the layer format. (`catalogList` formats catalog definitions, not stack layers.)

    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift
    - next: /review

    ### test — green
    - evidence: `swift build --build-tests` Build complete!; `swift test --skip-build` 2232 tests in 237 suites passed (1 known issue, HarnessSmokeTests, which was there before this change)
    - next: /review
  timestamp: 2026-11-18T13:56:20.046823+00:00
- actor: claude-code
  id: 01m7qf78whk29ygdhdccjt9wpv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (439642d); 0 findings, 0 confirmed, 0 refuted; 1 file reviewed. All prior findings are checked.
    - next: none. The task is in done.
  timestamp: 2026-11-18T13:58:26.961004+00:00
- actor: claude-code
  id: 01m7qf7q3my9ctj7bwx1qj855y
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift
    - test: green — swift test --skip-build, 2232 tests in 237 suites passed
    - commit: 439642d
    - review: clean — 0 findings; the finding at SettingsFoldersTests.swift:281 is checked
  timestamp: 2026-11-18T13:58:41.524160+00:00
position_column: done
position_ordinal: fffffd80
title: 'D200: add the built-in layer of the skills stack (Multitool skill folder)'
---
Decision D200 in `TestudoApp/features/decisions.md` (commit d1895ba); read D199 before it. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-sessions-skill.md`, change items 1, 2 and 4. Draft skill text: `sessions-skill-SKILL.md` in the same folder.

## Dependency

FoundationModelsMultitool (`mt-brief-sessions-skill.md`): Multitool ships the `sessions` skill as a resource and gives its folder as `BuiltinSkills.directory` (the name can change). Do not start until that change is available.

## Current behavior

- `SettingsFolders.stack(for:workingDirectory:)` (`Sources/FoundationModelsACPAgent/Configuration/SettingsFolders.swift:89-96`) makes `DotfolderStack` with no `defaultsDirectory`. `DotfolderStack` adds a defaults layer only for `<NAME>_DEFAULTS_DIR` or a given `defaultsDirectory` (`FoundationModelsExtras/.../DotfolderStack.swift:146-151`).
- `ToolCatalog.makeSkillsSource(context:marketplaces:sessionAgent:)` (`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:974-992`) makes the `SkillsRegistry` over that stack.
- Today the shipped skills come only from the default marketplace (`Resources/builtin.config.yaml:81-93`). It needs the network, and a user can set an empty list.

## Change

1. In `SettingsFolders.stack(for:workingDirectory:)`, for `.skills` only, give `defaultsDirectory: BuiltinSkills.directory`. The environment override `SKILLS_DEFAULTS_DIR` still wins. The precedence: marketplace < built-in < user (`Agents/_skills/`) < project (`<cwd>/.skills/`).
2. The `skills` tool and the endpoint show the built-in skill with its layer (`defaults`). A write never goes to that layer (D175): `add skill` of the name `sessions` writes the user layer, and that skill replaces the built-in skill.
3. The CLI (`acp-agent`) gets the same built-in layer.
4. Do not change the preload code or `InstructionsAssembler`. Do not set `preload: true` on the skill.

## Tests

- `SettingsFolders(...).stack(for: .skills, ...)` has a defaults layer at `BuiltinSkills.directory`. With `SKILLS_DEFAULTS_DIR` set, the override is the layer.
- The other kinds of stack have no new defaults layer.
- A `SkillsRegistry` from `makeSkillsSource` lists `sessions` with an empty marketplace list. A user layer `_skills/sessions/SKILL.md` replaces it.
- `add skill` named `sessions` writes the user layer, not the built-in folder.
- The CLI stack also lists `sessions`. #d200 #sessions-skill

## Review Findings (2026-11-18 07:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 32 not reviewed.

> 32 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 32 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/SettingsFoldersTests.swift:281` `reuse/reuse` — `lowestSkillsLayer` rebuilds the `<source>:<root path>` string that the existing `layerList(of:)` helper already produces for each layer. Writing the formatting a second time means two copies of the layer-label format can drift apart, and a change to one will not reach the other. Replace the body of `lowestSkillsLayer` with `try #require(Self.layerList(of: settingsFolders.stack(for: .skills, workingDirectory: workingDirectory)).first)`. Keep the `#require` so an empty stack still fails the test.
