---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4jsag4f7sa54d90ncnf354y
  text: |-
    Research done. Discoveries:
    - `ToolCatalog.makeSkillsSource` makes a `MarketplaceStore` only when `tools.skills.marketplaces` is not empty, and it awaits `store.start()`. `start()` contacts each git remote one time (ls-remote, and a fetch on a cold cache). Thus with the new default, each session start contacts github.com, and it waits for that work.
    - The store cache directory comes from the process environment (`MarketplaceStore.cacheDirectory()`). A unit test that uses a marketplace would write into the real cache of the user.
    - The existing unit tests do not use a marketplace at all. No test made a `MarketplaceStore` before this task. The tests get their configuration from two places: (1) `makeStubAgent` and `ComposedPromptFixture` give each agent the defaults layer of `StubAgentDefaultsLayer` (today it sets `codeContext: false` only); (2) about ten suites make a `CatalogContext` direct from `AgentConfiguration()`. With the new default, both paths would contact github.com.
    - `ToolsDoctor` and `RuntimeDoctor` do not state the skills marketplaces. RuntimeDoctor states only the dotfolder layers. Thus step 6 needs no change.
    - Integration tests: `LiveAgent` (ToolCalling, SkillTrigger) and the spawned binaries (configHome only) also use the default configuration.
    Plan: default list in `SkillsToolOptions`; `makeSkillsSource` reads the cache directory from `context.environment`; `StubAgentDefaultsLayer` sets `marketplaces: []`; the direct `CatalogContext` suites set `marketplaces: []` through one helper; a new unit test uses a local git repository (`file://.../skills.git`, `ref: main`) as the marketplace.
  timestamp: 2026-10-10T11:31:40.815296+00:00
- actor: claude-code
  id: 01m4jv2sym0yd9phfv829wdg3w
  text: |-
    Implementation landed; root suite green (855 tests, 91 suites, 1 known issue that existed before).
    - Default: `SkillsToolOptions.defaultMarketplaces` = HTTPS `swissarmyhammer/skills.git`, ref `main`; `init()` and an absent `marketplaces` key give it. builtin.config.yaml states the same list with an STE comment. Bench config, ToolSectionCodec doc example and README changed to `ref: main`.
    - `makeSkillsSource` now reads the store cache folder and the seed folder from `CatalogContext.environment` (production: the process environment, as before). This lets a test give its own cache folder.
    - No network in the unit tests: `StubAgentDefaultsLayer` sets `marketplaces: []`; `AgentConfiguration.withoutMarketplaces` (TestSupport) is used by ToolCatalogTests, AgentsToolTests and SkillsLibraryTests; `ConfigCommandFixture.stubEnvironment` became `makeStubEnvironment()` and now adds the stub defaults layer.
    - Discovery: a first full run with `SKILLS_MARKETPLACE_CACHE` set to an empty probe folder showed a real github fetch. Bisect found RunCommandTests: `ConfigCommandFixture.stubEnvironment` gave no defaults layer. After the fix the probe folder stayed empty for the full root suite.
    - `config show --source`: the keys of a marketplace entry are lines of a sequence item and carry no annotation (the list key carries it). The `keyLines` helper of ConfigShowTests now skips the lines of a sequence item.
    - New tests: ToolSectionCodecTests (default is main over HTTPS; `skills: true` keeps it; a user layer `marketplaces: []` gives none), SkillsMarketplaceTests (a stub session reads no marketplace; a local git repository `file://…/skills.git` on `main` gives its skill and its agent, cache in the context folder).
    - ToolsDoctor and RuntimeDoctor do not state marketplaces, thus step 6 needs no change.
  timestamp: 2026-10-10T12:02:25.876913+00:00
- actor: claude-code
  id: 01m4jvr4107s7v90fpej4vby51
  text: |-
    ### implement — changed
    - evidence: root `swift test --scratch-path .build/alt --force-resolved-versions`: 855 tests in 91 suites passed, 1 known issue that existed before; with `SKILLS_MARKETPLACE_CACHE` set to an empty probe folder, the folder stayed empty (no unit test fetched GitHub). IntegrationTests `--no-parallel` (scratch IntegrationTests/.build/alt): 30 tests in 11 suites passed. Python: bench 254 OK (1 skip: "swebench is not installed", it existed before), swebench/scripts 38 OK, swebench-score/scripts 34 OK. Build warning "missing creator for mutated node … mlx-swift_Cmlx.bundle" comes from SwiftPM and existed before.
    - files: Sources/FoundationModelsACPAgent/{Configuration/ToolSectionCodec.swift, Resources/builtin.config.yaml, Tools/ToolCatalog.swift, Tools/CatalogContext.swift}, README.md, bench/code-context.config.yaml, Tests/FoundationModelsACPAgentTestSupport/{StubProfileFixtures.swift, AgentConfigurationWithoutMarketplaces.swift (new)}, Tests/FoundationModelsACPAgentTests/{SkillsMarketplaceTests.swift (new), ToolSectionCodecTests.swift, ConfigShowTests.swift, ToolCatalogTests.swift, AgentsToolTests.swift, Integration/SkillsLibraryTests.swift, RunCommandTests.swift, ExitCodeTests.swift, CompositionInterruptTests.swift, Support/ConfigCommandFixture.swift, Support/ComposedPromptFixture.swift, Support/GitVerbSupport.swift}, IntegrationTests/…/{ToolCallingTests.swift, SkillTrigger/SkillTriggerSubject.swift}.
    - open: the spawned-binary suites of IntegrationTests fetch the default marketplace from GitHub (measured with a probe folder); new task 01M4JVQQ28G2E0FV2EW8ZJQM5D records the decision.
    - next: /review
  timestamp: 2026-10-10T12:14:04.320763+00:00
- actor: claude-code
  id: 01m4jw6abwzzxxed1ykjbe3j6p
  text: |-
    ### test — green
    - evidence: swift test --scratch-path .build/alt --force-resolved-versions (SKILLS_MARKETPLACE_CACHE = empty scratch folder, still empty after run) — 855 tests in 91 suites passed, 1 known issue (expected withKnownIssue in HarnessSmokeTests). swift test --package-path IntegrationTests --no-parallel — 30 tests in 11 suites passed. python3 -W error -m unittest discover: bench 254 run OK (skipped=1, expected "swebench is not installed"); swebench scripts 38 OK; swebench-score scripts 34 OK. Only warning: mlx-swift_Cmlx.bundle "missing creator for mutated node" (expected dependency warning). No code changes.
    - next: none
  timestamp: 2026-10-10T12:21:49.564568+00:00
position_column: doing
position_ordinal: '80'
title: Read the skills marketplace from swissarmyhammer/skills main, in the builtin default and in the bench config
---
## Goal

The user decided on 2026-10-10: the agent gets its skills (and its marketplace agents) from `swissarmyhammer/skills` on the `main` branch, from now on.

## State now

- `bench/code-context.config.yaml` names the marketplace `https://github.com/swissarmyhammer/skills.git` with `ref: code-context`. That branch has only 7 skills (code-context, commit, detected-projects, explore, lsp, map, tdd). `main` has 23 skills and the agents.
- `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` has `marketplaces: []`. Thus, by default, the agent reads only the local dotfolder stack.
- The doc comment at `Configuration/ToolSectionCodec.swift:205` shows `ref: code-context` as the example.

## Change

1. **Builtin default.** In `builtin.config.yaml`, set `tools.skills.marketplaces` to one item: `url: https://github.com/swissarmyhammer/skills.git`, `ref: main`. Use the HTTPS URL only (the user decided on 2026-09-18 that a marketplace is HTTPS only). Write an STE comment. Change the Swift default of `SkillsToolOptions` the same way, so that the test "the builtin file decodes to exactly `AgentConfiguration()`" still passes.
2. **Bench config.** In `bench/code-context.config.yaml`, change `ref: code-context` to `ref: main`, and correct the comment that says the branch holds only the five code-context skills.
3. **Doc example.** Change the example at `ToolSectionCodec.swift:205` to `ref: main`.
4. **README.** State the default marketplace, and how to set it to an empty list.
5. **Tests.** A test checks the default marketplace (URL and `ref: main`). A user layer that sets `marketplaces: []` gives no marketplace. A test that uses the network must not run by default: use a local git repository as the marketplace in the tests.
6. **Doctor.** If `ToolsDoctor` states the skills marketplaces, check that it shows the new default.

## Notes

- The marketplace agents of `main` are still in the old layout `agents/<name>.md`. FoundationModelsAgents reads only `agents/<name>/AGENT.md` now. The skills session moves them; this task does not depend on that move.
- Run after ^c4a6mwy, because both tasks change the configuration files.

#config #tools