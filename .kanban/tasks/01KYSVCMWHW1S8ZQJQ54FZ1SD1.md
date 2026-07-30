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
Plan.md §14.1 source 1. Create `Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift` — `.action` closures capturing the session:

- `/compact` — run compaction now (records its `CompactionSegment`; the wire effect is the usual `usage_update`, §8.5).
- `/context` — fill, tokens, resolved context from Router's meter.
- `/memory` — print the assembled instructions with their per-file source headers (§3.2).
- `/status` — session id, cwd, model/profile, transcript path.
- `/config` — print the applicable configuration as YAML with comments; `/config export home|project` writes the current effective config to that layer's `config.yaml` (the §2.2 eject counterpart).
- `/help` — list registered commands with descriptions/hints.

Frontend verbs (`/quit`, clear-as-new) stay out — composer functions (§14.1). Builtin names are reserved in the registry (previous task).

- [ ] The six builtins registered
- [ ] `/config export` writes the named layer
- [ ] `/compact` triggers a real fold on the scripted session
- [ ] Output streams as `.action` text (no model turn)

## Acceptance Criteria
- [ ] `/help` output names all six; `/status` output contains the sessionId and cwd
- [ ] `/config export project` creates `<cwd>/.<name>/config.yaml` whose content round-trips through the loader to the same effective configuration
- [ ] `/memory` output contains the absolute-path headers of every assembled instructions file
- [ ] None of the six invokes the scripted model backend

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/BuiltinCommandsTests.swift` — harness; assert streamed text content and filesystem effects
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.