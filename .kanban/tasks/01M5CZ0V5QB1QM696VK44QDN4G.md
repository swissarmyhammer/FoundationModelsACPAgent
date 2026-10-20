---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'ACPA-15: the host gives the snapshot data directory'
---
## What
ACPA-15 (TestudoApp `features/packages/foundationmodels-acpagent.md`, D96): the store directory of the persistent snapshot timeline must stay in a folder that macOS does not clean. The CLI uses the XDG data home. The app uses Application Support. Never Caches or a temporary folder.

Now `AgentHooks.init(dataDirectory:)` (`Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:47-51`) makes the `SnapshotStore` in `<data>/snapshot`. Only `AgentHooks.dataDirectory(name:environment:)` (lines 65-69) gives `<data>`: `$XDG_DATA_HOME/<name>/hooks`, else `~/.local/share/<name>/hooks`. The host cannot give an other folder. `ComposedAgent.compose(...)` (`ComposedAgent.swift:135`, the call at line 148) always uses that helper.

Do this:
- Add an optional parameter `hooksDataDirectory: URL? = nil` to `ComposedAgent.compose(...)`. When it is not nil, use it for `AgentHooks(dataDirectory:)`. When it is nil, keep the XDG data home.
- Document on the parameter that the app gives a folder in Application Support (for example `<Application Support>/<bundle id>/hooks`), and never Caches or a temporary folder.
- The CLI (`Sources/acp-agent/AgentComposition.swift`) gives nothing, so it keeps the XDG data home.
- Do not change FoundationModelsHooks.

## Acceptance Criteria
- [ ] `ComposedAgent.compose` takes `hooksDataDirectory`, and the `SnapshotStore` uses `<hooksDataDirectory>/snapshot`.
- [ ] With no value, the folder is the same as before.
- [ ] The CLI behavior does not change.

## Tests
- [ ] A test composes an agent with a temporary `hooksDataDirectory`, runs one turn that writes a file, and finds the shadow folder of the session key under `<hooksDataDirectory>/snapshot`.
- [ ] A test that with no value the folder is `AgentHooks.dataDirectory(name:environment:)` for a given `XDG_DATA_HOME`.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-15