---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4rejqg1y17p8amcmakj38f9
  text: |-
    Research done.
    - RoutedACPAgent makes a ConfigurationLoader at three sites: `loadSessionContext(workingDirectory:)` (SessionSetup.swift; session/new, session/resume, session/load and the session/delete scan of SessionLifecycle.swift use it), `listableRecords(inProject:)` and `registryUserLayerRoot()` (SessionList.swift). ComposedAgent.compose makes the start-up loader.
    - Plan: `ConfigurationLoader` gets `transcriptLocation: TranscriptLocation? = nil`; `load()` puts it over the decoded value. RoutedACPAgent keeps the value and makes every loader through one factory `makeConfigurationLoader(workingDirectory:)`, so a later request path cannot miss it.
    - `config show` is a CLI command, and the CLI never gives a code override. `LoadedConfiguration.sources` is keyed by `DotfolderStack.Source`, which has no case for code. A new source case is not cheap, so the doc comment says that a code override is not shown in `sources` or in `config show`.
    - A session lists only after a prompt (the first prompt writes the index record), so the tests send one prompt.
  timestamp: 2026-10-12T16:19:22.753922+00:00
- actor: claude-code
  id: 01m4rgrx7vnng0f5zdwhw0n9a8
  text: |-
    Implementation landed (not committed).
    - The shared step: `ConfigurationLoader` has `transcriptLocation: TranscriptLocation?`; `load()` puts it over the decoded `transcripts.location`. `RoutedACPAgent.makeConfigurationLoader(workingDirectory:)` (SessionSetup.swift) is now the one place where the agent makes a loader: `loadSessionContext` (session/new, session/resume, session/delete) and SessionList (cwd path and registry path) use it.
    - There is no `session/load` handler in this agent; `session/resume` is the restore path.
    - The stub model records only the `session` event, never a `response` event, so `ResumeSessionFixture.waitForRecordedResponses` times out on a stub agent. The new tests poll for any event of the session.
    - Mutation check: with `transcriptLocation: nil` in the factory, the two override tests fail (transcripts in the wrong root); with the value, all pass.
    - The `config show` source is not shown: doc comments on `ConfigurationLoader.transcriptLocation` and `ComposedAgent.compose` say so.

    ### implement — changed
    - evidence: `swift build` exit 0. `swift test --filter 'TranscriptLocationOverrideTests|ComposedAgentTests|ConfigurationLoaderTests|ConfigShowTests|SessionListTests|SessionLifecycleTests|SessionResumeTests|TranscriptLocationTests|AgentCompositionTests|AgentEnvironmentTests'`: 112 tests in 10 suites passed. Files: README.md, Sources/FoundationModelsACPAgent/{ComposedAgent.swift, RoutedACPAgent.swift, Agent/SessionSetup.swift, Agent/SessionList.swift, Configuration/ConfigurationLoader.swift, Configuration/PacedStubModel.swift}, Sources/acp-agent/AgentComposition.swift, new Tests/FoundationModelsACPAgentTests/TranscriptLocationOverrideTests.swift (3 tests).
    - next: /review. Then reply to agentviewkit-d0 with the commit and the API.
  timestamp: 2026-10-12T16:57:42.395009+00:00
position_column: doing
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