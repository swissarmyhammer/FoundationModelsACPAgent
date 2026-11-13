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
- actor: claude-code
  id: 01m79tg5bqxveygh0t9kskzjdf
  text: |-
    ### review — findings
    - evidence: review sha eb8254c~1..eb8254c — 1 finding (1 confirmed, 1 refuted) — Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:698
    - next: make makeSnapshotFixture take a loader, and make makeStubScriptFixture call it. Then review again.
  timestamp: 2026-11-13T06:46:10.551476+00:00
- actor: claude-code
  id: 01m79tnz0f0xfpah6vp434f46r
  text: |-
    ### implement — changed
    - finding: HookCompositionTests.swift:698 `reuse/reuse` is done and checked.
    - change: `makeSnapshotFixture` now takes `loader: any ModelLoader` and `label`, not `script`. The eight snapshot callers pass `makeHookLayeredModelLoader(script:)` with the same script as before. `makeStubScriptFixture` writes the script file, then calls `makeSnapshotFixture(loader: ComposedAgent.makeStubLoader(gatedBy: nil, scriptedBy: scriptFile.path), label:)`. Thus the work tree and the fixture come from one helper. Only the test file changed. The work tree directory label stays `<label>-repo`, thus the behavior does not change. `swift format` formatted only the changed lines.
    - evidence: `timeout 900 swift test --filter HookCompositionTests` exit 0, 23 tests in 1 suite passed. `timeout 900 swift test` exit 0, 2056 tests in 223 suites passed, 1 known issue (the existing `withKnownIssue` in `HarnessSmokeTests`), zero compiler warnings. The only `warning:` line is the SwiftPM build-graph line `missing creator for mutated node` of the dependency bundle mlx-swift_Cmlx.bundle, which is not from this change. No commit.
    - next: /review
  timestamp: 2026-11-13T06:49:20.655004+00:00
- actor: claude-code
  id: 01m79trjm3p8y1529zvbbxk78g
  text: |-
    ### review — clean
    - evidence: review sha 216131a~1..216131a — 0 findings (attempted 7, failed 0). The prior finding at HookCompositionTests.swift:698 is checked.
    - next: none. The task moved to done.
  timestamp: 2026-11-13T06:50:46.275519+00:00
position_column: done
position_ordinal: ffffe780
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

## Review Findings (2026-11-13 00:44)

> Scope: `review sha eb8254c~1..eb8254c` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:698` `reuse/reuse` — makeStubScriptFixture rebuilds the body of makeSnapshotFixture: it makes a work tree with makeSnapshotWorkTree, then calls ScriptedPromptFixture.make with a loader and the same label and working directory. The only difference is the loader, which is a parameter that makeSnapshotFixture fixes to makeHookLayeredModelLoader. This is a near-match that was not extended, so the two fixtures can drift apart. Generalize makeSnapshotFixture to take a loader (or a closure that makes one) instead of a script. Then makeStubScriptFixture calls it with ComposedAgent.makeStubLoader(gatedBy: nil, scriptedBy: scriptFile.path), and the snapshot tests keep their current behavior by passing makeHookLayeredModelLoader(script:).
