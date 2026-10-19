---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Wire hooks and snapshots into the composition: dispatcher, SnapshotStore, SnapshotHook, snapshots capability'
---
Precondition (other boards): the FoundationModelsRouter cards 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1, 01M5AS7RT8YA6KWDKXHQHWVD8S, 01M5AS7SMW3YPN03DPRNE3MRVH and 01M5ARTTKAX3YESYT2N8D73HCT, the FoundationModelsMultitool card 01M5ARZYZEH6R4XB6SX5WCD6B3, and the FoundationModelsHooks cards 01M5ARTJJ62RQX50B47G76HHYR and 01M5ARZY6273C826RVHA8RM5M1 are done and pushed. Until then, this card is blocked.

## What
Connect the hook system and the snapshots to the ACP agent. Router emits the events and owns the lineage. This package makes the shared objects, gives them to their clients, and marks a model-switch replacement. Use symbol names, not line numbers.

Facts that this card depends on:
- The ACP session id is the id of the Router session (`SessionId(rawValue: session.id.description)` in `SessionSetup.swift`). The default hook key of a Router session is its `id`, so the hook key of a new ACP session is already the ACP session id. No key is set when the session is made.
- A resume goes through Router's restore path (`restoreSession` / `restoreSessionTree`), which keeps the recorded `id` and emits `SessionStart(.resumed)`. This package sets nothing for a resume.
- The `snapshots` capability reads its key from `HookSession.current` at call time, so it needs no key when the tool surface is built.

Work:
- `Package.swift`: add `FoundationModelsHooks` as a remote family dependency on `main` (the same convention as `FoundationModelsRouter`), with a doc comment for the dependency name.
- `ComposedAgent.compose` (`Sources/FoundationModelsACPAgent/ComposedAgent.swift`): make one `HookDispatcher(dataDirectory:)` and one `SnapshotStore(directory: <dataDirectory>/snapshot)`. The data directory is `$XDG_DATA_HOME/acp-agent/hooks` (default `~/.local/share/acp-agent/hooks`). Give the dispatcher to `Router.init(hooks:)`, and register `SnapshotHook(store:)` on it.
- Add the method `RoutedACPAgent.registerHookVisitors(_ visitors: [any HookVisitor])`, in the same style as the method `RoutedACPAgent.registerHostTools`. It calls `dispatcher.register` for each visitor. A host or a test uses it to add visitors after the agent is made.
- `ToolCatalog.sessionSurface` (`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift`): add `SnapshotsCapability(store:)` to the Multitool registry of the session.
- `applyModelSlot` (`Agent/ConfigOptions.swift`): make the replacement session with `hookSessionKey` = the ACP session id and `hookOrigin: .replacement`.
- Shutdown: `RoutedACPAgent.closeOpenSessions` (`Agent/SessionLifecycle.swift`) runs when the connection ends, for `acp-agent acp` and for `acp-agent run`. After the sessions close, await `dispatcher.drain()`, so that the last snapshots are complete before the process exits.

## Acceptance Criteria
- [ ] A new session, one prompt with a tool call that writes a file, then a close: a recording visitor added with `registerHookVisitors` gets `SessionStart`, `PrePrompt`, `PreToolUse`, `PreToolResult`, `PostToolUse`, `PostPrompt` and `SessionEnd`, all with the ACP session id as `sessionKey`.
- [ ] After a model-slot switch, the replacement session has the same `sessionKey`, and `origin: .replacement`.
- [ ] A resumed session gets `SessionStart(.resumed)` with the ACP session id as `sessionKey`.
- [ ] In a temporary git work tree, a tool call that writes a file, then `dispatcher.drain()`, then `list snapshots` through the session's Multitool: one checkpoint. Then `undo snapshot` restores the file.
- [ ] When the connection ends, `closeOpenSessions` returns only after the dispatcher drained.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift` (Swift Testing, `@Suite(.closesHarnesses)`): each criterion above, with `AgentClientHarness` and `ScriptedModel` from `FoundationModelsACPAgentTestSupport`. Call `dispatcher.drain()` before each assertion on post events or on snapshots, because they are async.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks #blocked-external