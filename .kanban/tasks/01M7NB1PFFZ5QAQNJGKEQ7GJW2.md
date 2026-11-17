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
position_column: doing
position_ordinal: '80'
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