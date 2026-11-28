---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8gz0ztddsfg6arsx4ng9ya3
  text: |-
    Links from testudoapp-4f (2026-11-28):
    - Blocker: Router card ^xqgza86 on the foundationmodelsrouter-2b board. It waits for the Extras probe and mlx-swift-lm. testudoapp-4f will tell us when Router lands.
    - Testudo cards that wait for this card: ^xq74sya (session effort) and 01M8GZ07675M4WEVPAMB3MBWKK (Settings Default Reasoning Effort). The second card needs `profiles.<name>.effort` and the levels of each profile in the `models` endpoint. Do these two parts first, if possible.
    - When this card is done, tell testudoapp-4f.
  timestamp: 2026-11-28T11:35:39.085216+00:00
- actor: claude-code
  id: 01m8h9vdvprhr1g1zeph79zjdj
  text: |-
    2026-11-28: the Router API for ^xqgza86 (local commits 9bf9101c and a096ec68 in FoundationModelsRouter, not pushed yet):
    - `RouterSessionDirectory.setReasoningEffort(_ level: String?, of id: ULID) async throws -> SessionSummary` and `reasoningEffort(of:) async throws -> String?`.
    - `SessionSummary.reasoningEffort: String?` (also in `SessionFacts` and `index.md`).
    - `reasoningEffortLevels: ReasoningEffortLevels` on the model containers and `RoutedLLM` (`.unsupported` when the model has no levels).
    - `useReasoningEffort(_ level: String?)` on the session backend.
    - `SessionConfiguration` has a new effort field (see `Session/SessionConfiguration.swift` and `Session/SessionReasoningEffort.swift`).
    Dependencies are on `main` from GitHub, not path. Start when testudoapp-4f sends the pushed sha. Then run `swift package update FoundationModelsRouter`.
  timestamp: 2026-11-28T14:44:51.190204+00:00
- actor: claude-code
  id: 01m8hcdg44z10htcsmz37y4xq4
  text: |-
    2026-11-28 implementation notes:
    - Option: `ConfigOptions.EffortOption` (Agent/EffortConfigOption.swift), id `effort`, category `thought_level`, values = `sessionLevelNames`, current = Router level. Order: model, effort, agent. All announcements go through `configOptions(of:showing:)`, so session/new, resume, fork, set response and reconcile push agree.
    - A model change: a direct model set answers the new levels in its response (the response is the announcement, no push, as before). A switch that waits for an open prompt, and a held fork that moves, push one config_option_update through reconcile.
    - `profiles.<name>.effort`: new section `profiles` (ProfilesConfiguration), new SectionSchema case `.namedEntries`. session/new gives the value for the resident profile as `reasoningEffort:`; an unknown value logs the new ConfigurationWarning `.unknownEffort` and passes nil (default level).
    - models endpoint: `reasoningEffort { levels defaultLevel hasOff sessionLevels }` on SlotModel, ProfileModel and ModelProfile (standard model). Levels come from a JSON record `<local>/reasoning-effort/levels.json` (ReasoningEffortLevelsRecord) that the agent writes at launch for its standard and flash models. So a profile gives levels after the first load of its model on this machine. Not in the model cache folder, because a custom home puts the HF cache at `<local>/models`.
    - settings tool: query `reasoningEffort` and mutation `setReasoningEffort(level:)` on the settings endpoint. The session comes from `ToolContext.current.sessionID`; a call of the endpoint (no tool) gives NO_SESSION. The change pushes one config_option_update. Proven end to end through runCode in ReasoningEffortOptionTests.
    - Scripted model: ScriptedLLMContainer/ScriptedSessionBackend carry `reasoningEffortLevels`; the observer gets `reasoningEffortWillApply(_:)`, which the test ReasoningEffortRecorder reads.
    - The new Router made `RoutedSession.reasoningEffortLevels` a requirement: CloseCountingRoutedSession forwards it.
    - TestudoApp makes its own ModelsGraph before the agent (SAHKit AppAgent.swift); it must pass `effortLevels: ReasoningEffortLevelsRecord(fileURL: home.reasoningEffortLevelsFile)` to get levels there.
  timestamp: 2026-11-28T15:29:40.484626+00:00
- actor: claude-code
  id: 01m8hck1f4bnfdhqg9wh7t9agy
  text: |-
    ### implement — stuck
    - evidence: Router 62af1d7f, Extras dfc22d87, mlx-swift-lm 86dfc598 resolved. `swift build --build-tests`: Build complete!, no warnings. Focused suites: 43 tests in 4 suites passed. Full run (before the last fix): 2925 tests, 3 failures. Fixed after that run: settings rule 7 (setReasoningEffort now takes `input: SetReasoningEffortInput!`). Open: settings.graphql golden file needs a new record (GRAPHQL_GOLDEN_RECORD=1); CLIParsingTests.noSubcommandOfTheTreeIsAStub fails because ~/.config/acp-agent/config.yaml of this machine has an unknown `cluster:` section (not this card).
    - next: on END from the coordinator, record the golden file, run the full suite one time, then the card goes to review.
  timestamp: 2026-11-28T15:32:42.084720+00:00
- actor: claude-code
  id: 01m8hd437r8bgjmxs3vr9h5wak
  text: |-
    ### implement — changed
    - evidence: Build complete! with no warnings. settings.graphql recorded again (only the new ReasoningEffort type, SetReasoningEffortInput, the query and the mutation). Full `swift test --skip-build`: 2925 tests in 315 suites passed, 1 known issue (HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps, an intended withKnownIssue). Not committed.
    - next: /review.
  timestamp: 2026-11-28T15:42:00.952406+00:00
position_column: done
position_ordinal: ffffffc380
title: Reasoning effort as a thought_level session config option (D218)
---
## Source

Brief from the Testudo coordinator (testudoapp-4f), decision D218: `/Users/wballard/github/swissarmyhammer/.briefs/effort/FoundationModelsACPAgent-thought-level-option.md`.

Dependency: the FoundationModelsRouter session level (`.briefs/effort/FoundationModelsRouter-session-effort.md`). That brief depends on the FoundationModelsExtras probe and the mlx-swift-lm level value. Do not start this work until the Router gives the levels of each model and a level for each session.

## What to do

1. In `Sources/FoundationModelsACPAgent/Agent/ConfigOptions.swift`, add a second option when the model of the session has levels: category `thought_level`, type `select`, id `effort`, name "Reasoning Effort". The values are the levels of the model in the order of the probe, with the names of the model (no map). "Off" is last when the model has an Off level. The current value is the level of the session.
2. Put the option in the `session/new` response, the `session/set_config_option` response and each `config_option_update`. A set changes the level of the Router session from the next turn.
3. A model with no levels (the `small` profile): no option.
4. When the model of the session changes, send a `config_option_update` with the levels of the new model.
5. The `models` endpoint: give the levels, the default level and the Off flag of each loaded model. For each profile, also give the levels and the default level of its `standard` model. When the model is not loaded, it is acceptable to give them only after the first load, or to compute them from the tokenizer files.
6. The `settings` tool (D100) can set the level of the agent's own session.
7. New setting key `profiles.<name>.effort`: the default effort of new sessions on that profile. The `settings` tool and the `settings` endpoint read and write it at the user level and the folder level. `session/new` gives the value to the Router session. A value that is not a level of the model gives a configuration warning, and the session takes the default level of the model. This is not a failure of `session/new`.

## Acceptance criteria

- [ ] Fake model with three levels: `session/new` has the `effort` option with three values and the default value.
- [ ] A set to `low` gives a `config_option_update` with `low`, and the next turn of the Router session uses `low`.
- [ ] Model with no levels: no `effort` option.
- [ ] A change of model sends a `config_option_update` with the levels of the new model.
- [ ] The `models` endpoint has the levels, the default and the Off flag of each loaded model and of the `standard` model of each profile.
- [ ] `profiles.<name>.effort` reads and writes at the user and folder levels. A value that is not a level gives a warning and the default level.
- [ ] The `settings` tool sets the level of its own session.

## Coordination

Before UI tests or traces, ask testudoapp-4f for a screen or CPU slot. Send START and END lines to testudoapp-4f. #feature #blocked-external