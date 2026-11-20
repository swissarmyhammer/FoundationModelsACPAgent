---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nb2by13461tv2atf41n5d8
  text: |-
    The user adds: users can add profiles, and also through a tool.
    - A new `ProfileFile` type in this package (with its loader) is the one parser for every layer. Its errors name the file and the key.
    - The `models` endpoint gets mutations, so the agent tool and the Models pane can manage profiles: `saveProfile(name, profile, layer: user|project)` writes `<dotfolder>/profiles/<name>.yaml` after the same validation as the loader, and `deleteProfile(name, layer)` removes one. A bundled profile is read-only. A user file with the same name overrides it, and deleting that file brings the bundled one back.
    - `Query.profiles` lists every available profile with its layer (bundled/user/project).
    - Selecting a profile stays `updateSetting(keyPath: ["profile"], …)`.
    - The tool description text in ToolCatalog.swift:518 is updated.
  timestamp: 2026-11-17T18:07:23.073535+00:00
- actor: claude-code
  id: 01m7nbeedvm8cje6esk5ejd6nr
  text: 'User decision: a profile file may leave out `decision` and `decisionContext`; they take Router''s defaults (h2o-lightning GGUF, 16384). The required slots are standard, flash and embedding. `context` is optional. The known keys are name, description, standard, flash, embedding, decision, context, decisionContext and kvBits. A `name` key that differs from the file name is an error.'
  timestamp: 2026-11-17T18:13:58.843233+00:00
- actor: claude-code
  id: 01m7nbf3zf73z8q96zmy5p16mh
  text: 'The user''s final rule replaces the previous comment: every key of a profile file is optional, and a missing key takes the default from the bundled default profile `large`. The store merges the file''s top-level keys over `large` (a slot list replaces the slot as a whole), then decodes as ProfileDefinition. There is no required-slot check. An unknown key and a bad value are still errors. The name is always the file name.'
  timestamp: 2026-11-17T18:14:20.911402+00:00
- actor: claude-code
  id: 01m7nbgej8hqr9q83wmaqqb639
  text: 'Picked up. Research: ProfileConfiguration (AgentConfiguration.swift) is a map with name/description/preset/kvBits and is resolved via presetProfile; callers: RoutedACPAgent.resolveResident, ProfileDoctor, ModelsEngine (selectedProfile reads profile.preset at user level), ModelsGraphChanges (presetKeyPath), SettingsStore.retiredKeyPath, ConfigurationWarning.retiredHint, ConfigurationDoctor fix. D193 = `ToolContext.current?.parentSessionID != nil` guard in SettingsMarketplaceSourceStorage. YAMLValue(graphQLMap:) / graphQLMap exist in SettingsGraphSchema; ConfigurationYAML.levelText(of:) renders a YAMLValue mapping. Resources are `.copy` in Package.swift. RoutedACPAgent has no working directory, so the resolved profile (with the project layer) must ride in the loaded configuration. Coordinator decisions applied: known keys name/description/standard/flash/embedding/decision/context/decisionContext/kvBits; every key optional, merged at top level over bundled `large`; name key must equal file name; unknown key / bad value are errors naming file and key; kvBits accepted, not wired.'
  timestamp: 2026-11-17T18:15:04.520645+00:00
- actor: claude-code
  id: 01m7nbghw3gftyyvadnmq56td8
  text: |-
    User decision on the bundled profiles: only two.
    - `large` (the default): Qwen3.8-27B-8bit + MTP-8bit, for standard and flash.
    - `small`: Qwen3.8-27B-4bit + MTP-4bit, for standard and flash.
    Both have today's embedding and decision, and neither sets kvBits. medium and tiny are dropped. The default model moves to 8-bit, which needs mlx-swift-lm ^fgqcbvj (the 8-bit MTP drafter) for a real load.
  timestamp: 2026-11-17T18:15:07.907112+00:00
- actor: claude-code
  id: 01m7ndymvpxpsdr1e7ace0a8y9
  text: 'Progress: committed 5e3934c (bundled large/small + ProfileFile decode) and cb775fa (ProfileStore). Then in one working tree: `profile: <name>` (scalar; old map form: preset gives the name, other keys warn), loader reads the selected file for its cwd (unknown name lists every name), kvBits key + makeRouter/makeLiveModelLoader kvBits path removed, Router 63e4c70 + Extras 1c69b4f (loadLLM kvCache arg; profile kvBits now decodes for real), settings child-run guard (CHILD_RUN), models endpoint layer field + saveProfile/deleteProfile + profile-store change feed, CLI `acp-agent profiles list|show|save|delete`, doctor warning per bad profile file, README/ARCHITECTURE. Discovery: ModelsGraphTests.aModelOfAnOtherProfileGivesADiskChangeWithNoSlot hung forever (awaits a DISK change of a model no profile names any more) — that one hang stalled whole filtered runs; fixed to use small''s drafter. Child-run guards were proven by disabling them: 4 tests failed, restored.'
  timestamp: 2026-11-17T18:57:46.870095+00:00
- actor: claude-code
  id: 01m7neagv5z2gx2vt5g4ghethz
  text: |-
    ### implement — changed
    - evidence: commits 5e3934c, cb775fa, f98ee74 (49 files in f98ee74). `swift build -c release` complete; `swift test`: 2278 tests in 242 suites passed (1 known issue, pre-existing in HarnessSmokeTests). Router 63e4c70 + Extras 1c69b4f via `swift package update` (Package.resolved is gitignored).
    - decisions: bundled = large (8-bit) + small (4-bit) per user; profile name = file name (ProfileDefinition.name is "large", not the dotfolder name; /status shows it); `context` in a file is honored; reuse SettingsLevel (.user/.session) as the write layer and a new ProfileLayer {project,user,bundled} for reads; models endpoint takes an optional `cwd` for the PROJECT layer; Query.profiles skips files that do not decode (CLI list and doctor report them); doctor reports a bad file as a warning (the selected bad file already fails the load as an error); any `profile.<key>` set is refused; profile files are not template-rendered.
    - open: doctor memory floor stays 32 GB though large is now 8-bit (README says 32 GB for small, large needs more) — needs a measured figure; pre-existing compiler warnings in AgentSessionLauncherTests and MarketplaceRegistryMountTests (not touched).
    - next: /review
  timestamp: 2026-11-17T19:04:15.973401+00:00
- actor: claude-code
  id: 01m7x8k1wft6qvtpn458fdn504
  text: |-
    ### review — findings
    - evidence: `review sha 5e3934c~1..f98ee74` (commits 5e3934c, cb775fa, f98ee74); 49 files reviewed; the engine gave 14 findings (14 confirmed, 13 refuted). Each finding was checked against HEAD 9a87591. 2 findings are not open at HEAD and are not on the checklist: ModelsEngine.swift:111 (no `try?` now) and ProfileFileTests.swift:181 (bundled `small` has `kvBits: 8` now). 12 findings are open: Sources/FoundationModelsACPAgent/Configuration/ProfileStore.swift:410, :416, :431; Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift:578; Sources/FoundationModelsACPAgent/Models/ModelsGraphError.swift:80, :101; Sources/acp-agent/ProfilesCommand.swift:51; Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:1016, :1029; Tests/FoundationModelsACPAgentTests/Doctor/DoctorRegistryTests.swift:98; Tests/FoundationModelsACPAgentTests/ProfileFileTests.swift:124; Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:345 (lines at f98ee74; the section gives the HEAD lines that moved).
    - note: The description of this card is older than the user decisions in the comments. The comments and the later cards are current.
    - next: Correct the 12 items in the "Review Findings (2026-11-20 13:44)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-20T19:57:59.567303+00:00
- actor: claude-code
  id: 01m7x96r7a1ca5kd7v8g6qdp8j
  text: |-
    Work on the 12 findings of "Review Findings (2026-11-20 13:44)". All 12 are checked.
    - ProfileStore.swift: the three `.forEach` closures are now for-in loops. The file has no `.forEach` now.
    - ProfileDoctor.swift: `diskFix` is now a computed property: "make space on the volume of the model cache, or " + `smallerProfileFix`. The file has one copy of the clause.
    - ModelsGraphError.swift and SettingsGraphError.swift: a new internal protocol `StoreCodedError` (Sources/FoundationModelsACPAgent/Settings/StoreCodedError.swift) holds the shared `coded(_:)` (`knownCode(of:) ?? error`) and the shared `withCodedErrors(of:)`. Each enum keeps only its own case list in `knownCode(of:)`, which gives `nil` for an error that it does not know. It is a protocol extension with static functions, thus no stored static. The callers in SettingsEngine and ModelsEngine did not change. New tests: StoreCodedErrorTests (3).
    - ProfilesCommand.swift: a new `AgentComposition.settingsFolders(environment:)`. `Profiles.makeStore`, `SnapshotsCommand.makeInventory` (it now reads `folders.home.hooksDirectory`) and `makeConfigurationLoader` call it. ConfigurationLoader.swift (library) takes the name and the home from its caller, thus it has no CLI step to share and did not change. New tests: 2 in AgentCompositionTests.
    - Profile-file test setup: a new shared helper `writeProfileFile(named:contents:in:)` in Tests/FoundationModelsACPAgentTests/Support/ProfileFileWrite.swift. ConfigurationLoaderTests (2 copies), DoctorRegistryTests and ExitCodeTests (one more copy of the same setup) call it.
    - ProfileFileTests: the new test `fourKVBitsGiveAFourBitKVCache` decodes `kvBits: 4` and expects `.bits4`.
    - ScriptedPromptFixture: `distinctFlashConfiguration` calls `setTestSlot(\.flash, ...)`.
    TDD note: the new tests were written before the production code, but the RED run was not done as a separate build; the first build failed on the test file only (the test enum did not conform to CodedError), which was a fault of the test, not a feature RED.
  timestamp: 2026-11-20T20:08:45.034946+00:00
- actor: claude-code
  id: 01m7x96w10gdfq9jj8eef7mh43
  text: |-
    ### implement — changed
    - evidence: 18 files — Sources/FoundationModelsACPAgent/Configuration/ProfileStore.swift, Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift, Sources/FoundationModelsACPAgent/Models/ModelsGraphError.swift, Sources/FoundationModelsACPAgent/Settings/SettingsGraphError.swift, Sources/FoundationModelsACPAgent/Settings/StoreCodedError.swift (new), Sources/acp-agent/AgentComposition.swift, Sources/acp-agent/ProfilesCommand.swift, Sources/acp-agent/SnapshotsCommand.swift, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift, ConfigurationLoaderTests.swift, Doctor/DoctorRegistryTests.swift, ExitCodeTests.swift, ProfileFileTests.swift, StoreCodedErrorTests.swift (new), Support/ProfileFileWrite.swift (new), Support/ScriptedPromptFixture.swift. `swift build --build-tests`: Build complete!, no warnings. Full root `swift test`: Build complete!, 2738 tests in 287 suites passed, 1 known issue (HarnessSmokeTests, it was there before), XCTest 0 tests 0 failures. 12 of 12 findings checked. Not committed.
    - next: /review
  timestamp: 2026-11-20T20:08:48.928456+00:00
- actor: claude-code
  id: 01m7x9cca66bdmxr5e25e1fhyy
  text: |-
    ### review — clean
    - evidence: `review sha f4e81d2~1..f4e81d2` (HEAD~1..HEAD); 16 files reviewed; 0 findings (0 confirmed, 2 refuted). All 12 items of the 13:44 section are checked.
    - next: none. The task is in done.
  timestamp: 2026-11-20T20:11:49.446424+00:00
position_column: done
position_ordinal: ffffffb880
title: 'Profiles are files: `profile: <name>`, named profile files per layer, builtins bundled with ACPAgent'
---
User decision, 2026-11-17. This replaces ACPA-21's `profile.preset`, my `profile.kvBits` key (7d66b77/c6a2d28) and ^6r566bt.

**Who owns what**
- Router: only the data model, `ProfileDefinition`, which gains `kvBits` (Router card, from foundationmodelsrouter). It resolves and loads with it.
- ACPAgent: `ProfileStore` beside `SettingsStore`, the bundled builtin profile files, `profile: <name>` in config.yaml, and the tools.
- Multitool: no change.

**Profile files**
- A profile is at `<dotfolder>/profiles/<name>.yaml` in the project layer, then the user layer, then the bundled resources `Resources/profiles/{large,medium,small,tiny}.yaml`. The bundled files are exact copies of today's Router `ModelProfiles.builtin`, so the default behavior does not change. A test checks that bundled `large` equals `ModelProfiles.named("large")`.
- The first layer that has the name wins, as a whole file, with no merge across layers.
- A file decodes as Router's `ProfileDefinition` (the name is the file name).
- Every slot is required: a missing slot is an error, not a default.
- An unknown key is an error, and the error names the file and the key.

**ProfileStore (ACPAgent, next to SettingsStore, with the same layers, folders, write path and change notices)**
- list: every available profile, each with its layer.
- read.
- save(name, profile, layer: user|project): validates by decoding before it writes.
- delete(name, layer).
- A bundled profile is read-only. A user or project file with the same name overrides it, and a delete brings the bundled one back.

**config.yaml**
- `profile: <name>`, a scalar. The default is `large`.
- An unknown name is an error that lists every available name.
- The old map form loads: `preset` gives the name. Every other key (name, description, standard, flash, embedding, decision, decisionContext, kvBits) gives a warning and is ignored.

**Tools (mounted in Multitool in ToolCatalog)**
- `settings` selects a profile: `updateSetting(["profile"], name)`.
- `models` (the existing endpoint, extended):
  - `Query.profiles` lists every profile with its layer.
  - The mutations `saveProfile(name, profile, layer)` and `deleteProfile(name, layer)` go through ProfileStore.
  - The tool text says that a change applies at the next launch.
- A child agent run cannot save, delete or select, as for marketplaces (D193).
- The tool description at ToolCatalog.swift:518 is updated.

**Other surfaces**
- The CLI: `acp-agent profiles list|show|save|delete` over ProfileStore.
- The Models pane uses the same endpoint.
- Doctor checks the resolved profile. A bad profile file is a finding.
- `config show` lists `profile: large`.
- README, and DocumentationSyncTests.

**kvBits**
- Remove the `profile.kvBits` config key and the `kvBits` parameter of makeRouter/makeLiveModelLoader.
- The KV bits come from the profile when Router's ProfileDefinition has `kvBits`. That step waits on the Router SHA.

TDD for every step.

#config

## Review Findings (2026-11-20 13:44)

> Scope: `review sha 5e3934c~1..f98ee74` — reviewed the diffs only — lines this change added or modified. 49 file(s) reviewed, 6 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/profiles/large.yaml` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/profiles/small.yaml` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsACPAgent/Configuration/ModelProfilesDefault.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsACPAgent/Configuration/ModelProfilesDefault.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsACPAgent/Configuration/ModelProfilesDefault.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsACPAgent/Configuration/ModelProfilesDefault.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsACPAgent/Configuration/ModelProfilesDefault.swift, so its declarations are unread

> The engine gave 14 findings. Each finding was checked against the file at HEAD (9a87591), as the coordinator told. 2 findings are not open, because HEAD has no such defect:
> - `Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:111` `swift/error-handling` — at HEAD, `selectedProfile()` has no `try?`. It throws the read error of the selected file, and it uses the fallback profile only for `ProfileStoreError.unknownProfile`, with a warning log.
> - `Tests/FoundationModelsACPAgentTests/ProfileFileTests.swift:181` `completeness/inverse-operation-coverage` — at HEAD, the bundled `small` profile has `kvBits: 8` (`.bits8`). Thus `theTextOfAProfileDecodesBack` does a round trip of `kvCacheQuantization`. The 4-bit value stays open in the item for line 124.
>
> The line numbers below are the lines at f98ee74. At HEAD: ConfigurationLoaderTests.swift:1016 is now about line 1027, :1029 is now about line 1040, ProfileFileTests.swift:124 is now about line 144, and ScriptedPromptFixture.swift:345 is now line 364. The other lines did not move.

- [x] `Sources/FoundationModelsACPAgent/Configuration/ProfileStore.swift:410` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ProfileStore.swift:416` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ProfileStore.swift:431` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
- [x] `Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift:578` `duplication/duplication` — The fix text of the disk row repeats the clause of the smaller-profile fix: 'set "profile: small" in config.yaml, with acp-agent config edit'. Both copies name the same profile, file and command. If one copy changes and the other does not, the two fixes give different instructions for the same action. Build diskFix from smallerProfileFix. Use the 'make space on the volume of the model cache, or ' prefix, then the shared smallerProfileFix text. Keep one copy of the clause.
- [x] `Sources/FoundationModelsACPAgent/Models/ModelsGraphError.swift:80` `reuse/reuse` — `ModelsGraphError.coded` repeats the shape of `SettingsGraphError.coded`: a `switch` over the error types of the store that maps each known store error to a coded case and returns any other error unchanged. The two functions differ only in the cases they match. A near-match like this could be generalized, for example by letting each enum supply its own mapping over one shared switch, so the wrapping logic is kept in one place. Share the error-to-code wrapping between the two enums. Either a shared helper takes a list of `(Error) -> (any Error)?` mappings, or the shared `withCodedErrors` from the first finding takes the mapping as a parameter. Keep each enum's case list in its own file.
- [x] `Sources/FoundationModelsACPAgent/Models/ModelsGraphError.swift:101` `reuse/reuse` — `ModelsGraphError.withCodedErrors` is a line-for-line copy of `SettingsGraphError.withCodedErrors`: it runs a store call in a do/catch and rethrows `coded(error)`. The copy duplicates the same error-wrapping behavior, so a fix to one, such as a change to how unknown errors pass through, will not reach the other. The only difference is which `coded` it calls, and that could be passed in as a parameter. Move the wrapper to one shared helper that takes the coded-error mapping as a closure or function value, for example `withCodedErrors(of: storeCall, coded: ModelsGraphError.coded)`, and have both `SettingsGraphError` and `ModelsGraphError` call it. If the helper must stay per-enum, at least extend `SettingsGraphError.withCodedErrors` so the two share one generic shape.
- [x] `Sources/acp-agent/ProfilesCommand.swift:51` `reuse/reuse` — `Profiles.makeStore` builds `SettingsFolders(name:home:environment:)` inline from `DotfolderName(AgentComposition.dotfolderName)` and `AgentComposition.home(environment:)`. The same construction is already written out in `SnapshotsCommand.makeInventory` (Sources/acp-agent/SnapshotsCommand.swift:33-37), in `AgentComposition.makeConfigurationLoader` (Sources/acp-agent/AgentComposition.swift:309-310), and in ConfigurationLoader.swift:326 and :352. The change adds a fourth copy of the same folder setup, so a future change to how the dotfolder name or home is resolved must be made in several places. Add one helper, for example `AgentComposition.settingsFolders(environment:) throws -> SettingsFolders`, that performs the `DotfolderName` and `home` steps. Call it from `Profiles.makeStore`, `SnapshotsCommand.makeInventory`, and `makeConfigurationLoader`. The helper can be added in this change, and the existing duplicates can be switched over in the same pass.
- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:1016` `reuse/reuse` — The test creates the project profiles folder and writes a profile file by hand (createDirectory, then String.write). The same setup appears in aBadSelectedProfileFileIsAnError (line 1029) and in DoctorRegistryTests.swift:98. A near-match exists in the test fixture's writeConfig(_:in:) helper, but it cannot place a file under profiles/. A shared fixture helper that writes a named profile file in a layer would keep one copy of this setup. Add one fixture helper, for example writeProfileFile(named:contents:in:), that creates the folder and writes the file. Call it from theNameSelectsAProjectProfileFile, aBadSelectedProfileFileIsAnError, and aBadProfileFileIsAFinding.
- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:1029` `reuse/reuse` — This is the second copy in the same file of the profile-file write setup that theNameSelectsAProjectProfileFile already has at line 1016. The copy adds a second place to change if the profile folder layout changes. Call the shared profile-file helper with the file contents as its parameter, as described for line 1016.
- [x] `Tests/FoundationModelsACPAgentTests/Doctor/DoctorRegistryTests.swift:98` `reuse/reuse` — aBadProfileFileIsAFinding builds the same profile-folder and file write as the two tests in ConfigurationLoaderTests.swift. It is a fresh copy of a setup that another test file already repeats. Move the setup into one shared test-support helper and call it from this test.
- [x] `Tests/FoundationModelsACPAgentTests/ProfileFileTests.swift:124` `completeness/inverse-operation-coverage` — The decode accepts two valid KV bit widths, 8 and 4, but the tests cover only 8 (positive) and 6 (negative). The 4-bit branch of the decode is never exercised, so a regression that maps 4 to the wrong case or rejects it would pass the suite. Add one test that decodes `kvBits: 4\n` and asserts `.bits4`. This is the second valid value of the same contract, so one assertion closes the gap.
- [x] `Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:345` `reuse/reuse` — distinctFlashConfiguration rebuilds the profile edit that the new setTestSlot helper already performs. It copies the resolved profile, assigns the flash slot, and writes the result back. A second copy of that three-step edit means a future change to setTestSlot would not reach this site. Replace the three lines with `configuration.setTestSlot(\.flash, ["mlx-community/Qwen3-4B-4bit"])` on a `var configuration = AgentConfiguration()`, then return it. The helper is in the same test target, so no new code is needed.