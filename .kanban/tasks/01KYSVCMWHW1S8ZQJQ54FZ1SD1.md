---
assignees:
- claude-code
depends_on:
- 01KYSVCAH5MAEMCH4R5A8MNCSF
position_column: todo
position_ordinal: '9380'
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