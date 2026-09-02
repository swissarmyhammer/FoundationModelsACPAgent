---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g27cwrg6c94vh18w1fzn5v
  text: |-
    ### research done
    Key facts found:
    - `CommandRegistry(builtins:providers:workingDirectory:)` holds `builtins` as an immutable `let`; `SessionSetup.composeSession` builds the registry with `builtins: []` BEFORE `makeSession`. The session, its id, and the transcript directory do not exist yet. `/help` must also read the registry, which contains the builtins. So a late-bound context box is needed: builtins capture it, the registry is built with those builtins, then the box is filled with the live session and the registry after `makeSession`.
    - `RoutedSession.compact()` and `contextFill` are public. `compact()` uses `TokenBudget(limit: contextTokens)` with defaults 0.80/0.50. Stub `contextTokens` = `ProfileDefinition.defaultContext` = 8192. A caller-driven fold does not degrade: a summarizer failure throws to the caller.
    - `contextFill` is `0` before the first turn (usageState `.none`), and `Double.nan` only for a restored session with no stamp (usageState `.unknown`). So the NaN branch cannot be reached from a fresh wire session; the NaN guard is tested as a pure formatter, and the integration test asserts the streamed line never contains "nan".
    - `CompactionResult` carries `tokensBefore`, `tokensAfter`, `summarizerModel` (the ModelRef stringValue, or nil for a deterministic-only or no-op fold).
    - `/status` model = `residentProfile.standard.chosen.stringValue`; profile = `residentProfile.definitionName`.
    - `/memory` prints `entry.instructions`; the assembler already puts `===== <abs path> =====` headers before each on-disk file.
    - No YAML encoder is a declared dependency (Yams stays inside Extras). `/config` will emit block YAML through a JSONEncoder -> JSONSerialization -> `YAMLValue` bridge plus a small block writer with section comments; the round-trip is verified by re-loading through `ConfigurationLoader`.
    - Test harness: `AgentClientHarness` + scripted/echo model; `CommandDispatchTests.Fixture` is the pattern (registerCommandProviders, initialize, newSession, collector). The echo model streams the prompt back, so "no chunk carries the prompt" proves no model turn ran.
  timestamp: 2026-09-02T03:22:27.608775+00:00
- actor: claude-code
  id: 01m1g3bqqfk42d15v17c1r66cm
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift (new), Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift (registry now assembled in newSession with the six builtins after the session exists), Tests/FoundationModelsACPAgentTests/BuiltinCommandsTests.swift (new), Tests/FoundationModelsACPAgentTests/CommandDispatchTests.swift (near-miss typo isolated to the provider so the builtins no longer widen the suggestion set).
    - design: the builtins capture a late-bound `BuiltinCommandContext` (a `Mutex`-guarded box) because the registry is built before the session exists yet `/help` must read the registry that carries the builtins. `/config` emits commented block YAML through a JSONEncoder -> JSONSerialization -> block writer; export writes to the layer's `config.yaml` and round-trips through the loader (proven, including an mcp server and non-default values).
    - note: `contextFill` is `0` before the first turn (state `.none`), not `Double.nan` (`.unknown`, restore only). The NaN branch cannot be reached over a fresh wire session, so the guard is proven by a pure formatter test plus an integration test that the streamed line never contains "nan".

    ### test — green
    - evidence: swift test — 229 passed, 0 failed, 0 skipped, 0 warnings (1 pre-existing withKnownIssue marker in HarnessSmokeTests). swift build clean.
    - next: commit.
  timestamp: 2026-09-02T03:42:18.351477+00:00
- actor: claude-code
  id: 01m1g3js8qv9atmmkck39nbrnm
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted. .kanban/ excluded by .reviewignore.
    - next: task moved to done.

    ### finish iteration 1 — done
    - implement: changed (BuiltinCommands.swift, ConfigurationYAML.swift, SessionSetup.swift, BuiltinCommandsTests.swift, CommandDispatchTests.swift)
    - test: green (229 passed, 0 failed, 0 warnings)
    - commit: fb96c6f
    - review: clean (0 findings) — task moved to done
  timestamp: 2026-09-02T03:46:09.303589+00:00
depends_on:
- 01KYSVCAH5MAEMCH4R5A8MNCSF
position_column: done
position_ordinal: '9180'
title: 'Builtin slash commands: /compact /context /memory /status /config /help'
---
## What
Plan.md §14.1 source 1. Create `Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift` — `.action` closures that capture the session:

- `/compact` — fold now. Call `RoutedSession.compact()`, or `compact(budget:)` for an explicit budget. Both are public. It returns a `CompactionResult` carrying `id`, `summary`, `summaryEntryId`, `summarizerModel`, `tokensBefore`, `tokensAfter`, `stagesApplied` and `summaryCut`. The wire effect is the usual `usage_update` (§8.5). **A caller-driven fold does not degrade**: unlike the automatic fold, the summarizer's error reaches the caller, so report a failed `/compact` honestly instead of claiming success.
- `/context` — the fill, the tokens and the resolved context from Router's meter. Read `RoutedSession.contextFill`. **It can be `Double.nan`** when no stamp exists yet, and the constant naming that is internal, so test `.isNaN` and print "not measured yet" rather than NaN.
- `/memory` — print the assembled instructions with their per-file source headers (§3.2).
- `/status` — the session id, the cwd, the model and profile, and the transcript path. Take the model name from `profile.standard.chosen.stringValue`, because `ModelRef`'s `repo` and `revision` are internal.
- `/config` — print the applicable configuration as YAML with comments. `/config export home|project` writes the current effective config to that layer's `config.yaml`, which is the §2.2 eject counterpart.
- `/help` — list the registered commands with their descriptions and hints.

Report `summarizerModel` in the `/compact` output. Upstream measured a real hazard: a `flash` model too small to summarize passes every mechanical check while writing garbage, and `summarizerModel` is the signal that lets a user see which model wrote the summary.

Frontend verbs such as `/quit` and clear-as-new stay out; they are composer functions (§14.1). Builtin names are reserved in the registry, which the previous task enforces.

- [ ] The six builtins registered
- [ ] `/compact` calls `RoutedSession.compact()` and reports a failure honestly
- [ ] `/compact` output names `summarizerModel`
- [ ] `/context` guards a NaN fill
- [ ] `/config export` writes the named layer
- [ ] Output streams as `.action` text, with no model turn

## Acceptance Criteria
- [ ] `/help` output names all six; `/status` output contains the sessionId and the cwd
- [ ] `/compact` on a scripted session reports the before and after token counts and the summarizer model
- [ ] A scripted summarizer failure makes `/compact` report the failure and not a success
- [ ] `/context` before the first turn prints "not measured yet" and never prints NaN
- [ ] `/config export project` creates `<cwd>/.<name>/config.yaml`, whose content round-trips through the loader to the same effective configuration
- [ ] `/memory` output contains the absolute-path headers of every assembled instructions file
- [ ] None of the six invokes the scripted model backend

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/BuiltinCommandsTests.swift` — harness; assert the streamed text content and the filesystem effects
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.