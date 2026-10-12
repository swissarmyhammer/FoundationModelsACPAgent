---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Let an in-process host set the transcript location in code
---
## Why

Request from the AgentViewKit session (2026-10-12): the AgentViewKit demo Gallery must run FoundationModelsACPAgent in its process (`ComposedAgent` + an in-process transport), not start the `acp-agent` binary. The Gallery restores recorded sessions from a temporary copy, so it must point the transcript location at that copy. Today only config files can do this (`XDG_CONFIG_HOME`, `userDirectory`, or `<cwd>/.acp-agent/config.yaml`), and the owner does not want config files for this.

Findings of the AgentViewKit session:
- `ComposedAgent.compose(name:workingDirectory:environment:modelSource:stubChunkDelay:reporting:)` has no parameter for a configuration, a `TranscriptLocation` or a `userDirectory`.
- `RoutedACPAgent.init(... configuration:)` uses `configuration` only to resolve the profile.
- Each session request reads the config files again: `session/new`, `session/resume` and `session/load` through `SessionSetup.loadSessionContext(workingDirectory:)`; `session/list` through `SessionList.listableRecords(inProject:)` and the registry path `allListableRecords()`. Each makes a new `ConfigurationLoader` and reads `transcripts.location` from the files, so a value given only at the start does not reach these requests.

## Decision

- `ComposedAgent.compose(...)` gets `transcriptLocation: TranscriptLocation? = nil`. When it is not nil, it wins over every config layer.
- The value goes into one place that every config load uses (the loader or the per-session context), not into each request path, so a later path cannot miss it.
- `config show` of an agent with the override shows it as the source of `transcripts.location`, if that is cheap; else the doc comment says that a code override is not shown.

## Work

1. Add the parameter to `ComposedAgent.compose` and keep it on `RoutedACPAgent`.
2. Apply it in the one shared config-load step, so `session/new`, `session/resume`, `session/load`, `session/list` (project and registry paths) all use it.
3. Update the doc comments and the README section on transcripts.

## Acceptance criteria

- An in-process agent with `transcriptLocation: .path(dir)` and `ModelSource.stub`, with no config files, writes new sessions in `dir`, lists them, and resumes them.
- With `nil`, the behavior does not change.
- The override wins over a `transcripts.location` in a project `config.yaml`.

## Tests

- An agent-level test with the harness: `transcriptLocation: .path(dir)`, no config files; `session/new`, close, `session/list`, `session/resume`; check that the transcripts are in `dir`.
- A test that the override wins over a project config value.
- A test that `nil` keeps the file value.

Reported by: agentviewkit-d0. Reply to it with the commit and the final API.