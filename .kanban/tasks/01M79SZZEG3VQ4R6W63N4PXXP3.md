---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m79t44efmsm5ngff354b5mj1
  text: 'Research. The app (TestudoApp) runs the agent with a stub script (`ACP_AGENT_STUB_SCRIPT`, `AppAgentTests` reads `composition.stubScript`). `ComposedAgent.makeStubLoader(gatedBy:scriptedBy:)` makes `ScriptedLLMContainer(playbook: .sessions(script))` with no wrapper. Router puts the tool layers (no-op check, repetition check, tool hook layer) only in the live backend of `LiveModelLoader`. Router (pin aff2f10) gives `HookLayeredLLMContainer` for a scripted container, and its doc says: a scripted container calls its tools directly, thus a tool call sends no `PreToolUse`, `PreToolResult` and `PostToolUse`. Thus `SnapshotHook` never sees a `PostToolUse` for a stub-script `runCode` call, and takes no snapshot. The in-process test `HookCompositionTests.aToolCallThatWritesAFileMakesOneCheckpointThatARollbackRestores` passes because its loader (`makeHookLayeredModelLoader`) wraps the scripted container in `HookLayeredLLMContainer`; the production stub path does not. Cause is in ACPAgent (the composition of the stub loader). Plan: a test over the loader of `makeStubLoader` in a git work tree, then wrap the scripted container in `HookLayeredLLMContainer`.'
  timestamp: 2026-11-13T06:39:36.399274+00:00
- actor: claude-code
  id: 01m79tbjfxpp2mm7y4ds1jg6m0
  text: |-
    ### implement — changed
    - cause: `ComposedAgent.makeStubLoader(gatedBy:scriptedBy:)` (Sources/FoundationModelsACPAgent/ComposedAgent.swift) made `ScriptedLLMContainer(playbook: .sessions(script))` with no tool layers. Router puts the no-op check, the repetition check and the tool hook layer on the tools of the live backend only. Thus a stub-script `runCode` call sent no `PreToolUse`/`PostToolUse`, and `SnapshotHook` took no snapshot. The dispatcher, `SessionStart`, the session key and the owner were correct (the in-process proof with `HookLayeredLLMContainer` already gave one checkpoint). The cause is in ACPAgent, not in Hooks or Router.
    - fix: the stub-script loader wraps the scripted container in Router's public `HookLayeredLLMContainer`. `makeStubLoader` is now `internal` (was `private`) so the test can call it.
    - tests: `HookCompositionTests.aStubScriptToolCallThatWritesAFileMakesOneCheckpointOfThatFile` (RED: checkpoints `[]`; GREEN: `[["note.txt"]]`), `HookCompositionTests.aStubScriptToolCallThatChangesNoFileMakesNoCheckpoint` (guard of the no-change rule; it passed before the fix too, because no hook ran then). Both use a stub script file, a git work tree, and the store after the drain of the dispatcher. No wall clock.
    - docs: README section of `ACP_AGENT_STUB_SCRIPT` tells that each tool call of a pass goes through the tool layers and makes a checkpoint for a changed file.
    - evidence: `timeout 900 swift test` exit 0, 2056 tests in 223 suites passed, 1 known issue (the existing `withKnownIssue` in `HarnessSmokeTests`), zero compiler warnings. One SwiftPM build-graph line `warning: missing creator for mutated node` (mlx-swift_Cmlx.bundle) comes from a dependency bundle, not from this change.
    - note: a stub script that repeats one identical tool call can now meet the repetition check, as the live model does. IntegrationTests stub scripts (ChildDeadlineTests) use no tool calls, thus they do not change.
    - next: /review
  timestamp: 2026-11-13T06:43:40.157900+00:00
position_column: doing
position_ordinal: '80'
title: A runCode call that writes a file in a git work tree makes no checkpoint
---
## What
Report of testudoapp-75 (2026-11-13), found by TestudoApp ^0ywamhb. On the agent of the app, a scripted `runCode` call that writes a file with `tools.files.write` in a git work tree makes NO checkpoint: `tools.snapshots.list` gives none after the turn. Only a rollback records the writes (it takes a snapshot first). Thus the timeline of the app never shows the file changes of the agent unless the model calls `tools.snapshots.take`.

Design today: FoundationModelsHooks `SnapshotHook` (Snapshots/SnapshotHook.swift) takes a snapshot on each `PostToolUse` (trigger `.toolUse(toolCallID:toolName:)`), after `SessionStart` opened the session key. FoundationModelsRouter fires `PostToolUse` (Session/ToolCallHooks.swift ~228). ACPAgent composes the hooks (Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift and the session setup).

1. Reproduce it in this package with a deterministic test: a session in a git work tree, a scripted runCode call that writes a file through `tools.files.write`, then `tools.snapshots.list` (or the store) after the turn. Expect one checkpoint with that file.
2. Find the cause. Candidates: the hook is not in the dispatcher of this session; `SessionStart` does not open the key (for example the session key or the owner is not the same as in the `snapshots` tool); `PostToolUse` is not fired for a scripted stub tool call or for `runCode`; the take finds no change (for example it reads another work tree, or the write is not on disk yet).
3. If the cause is in ACPAgent, fix it here. If it is in FoundationModelsHooks (pin 35e8810) or FoundationModelsRouter, do not edit them: report the exact cause, and the orchestrator sends it to the owner session.

## Acceptance Criteria
- [ ] A runCode write in a git work tree gives one checkpoint with that file after the call (or the turn).
- [ ] A call that changes no file makes no checkpoint (the existing rule of the hook).

## Tests
- [ ] The deterministic test above, which fails before the fix.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1