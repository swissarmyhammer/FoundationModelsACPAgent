---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5b39x1a463vd1ntcgj3bc64
  text: 'Preconditions met (checked with git ls-remote on 2026-10-19): Hooks origin/main 2e29e38 (all 7 cards done, with SnapshotStore.undoneCheckpoints), Router origin/main 1407ac3 (all 4 #hooks cards done), Multitool origin/main 7d63a26 (snapshots capability done). Facts from the Router session: (1) Router origin/main needs FoundationModelsExtras a63ddda or later, so update all four family pins in Package.resolved together. (2) The tool hook layer sits in Tool.sessionChecked between the tool and a new failure delivery; the no-op and repetition checks stay outermost. (3) The hook toolCallID equals the id of the toolCall session event. It is NOT the correlationID of toolCallReport, which is the run completion token by contract.'
  timestamp: 2026-10-19T22:07:53.386465+00:00
- actor: claude-code
  id: 01m5b3new9b7q0624804w9kpzq
  text: |-
    Research done (implement step). Facts that the card text does not have:
    - `Router.hooks` is internal. The agent cannot read the dispatcher from the router. Thus the composition makes one `AgentHooks` value (dispatcher + store, `SnapshotHook` registered) and gives the same value to `Router.init(hooks:)` and to `RoutedACPAgent.init(hooks:)`.
    - `RoutedACPAgent` has three construction sites: `ComposedAgent.compose`, `makeStubAgent` (test support) and `LiveAgent` (IntegrationTests). `EchoModel.makeRouter` gets a `hooks:` parameter.
    - The Multitool registry of a session is built in `ToolCatalog.makeRegistry(context:)`, which `sessionSurface` calls. The store goes through `CatalogContext`.
    - The model-slot switch vends through `RoutedLLM.makeBudgetedSession` (SessionSetup.swift). It gets `hookSessionKey` and `hookOrigin` parameters.
    - `SnapshotHook` uses the git ignore rules: ignored files are not in a tree. The session transcripts go to `<cwd>/.coding/transcripts`, so the snapshot test commits a `.gitignore` for `.coding/`.
    - A visitor registered after `session/new` does not get the `SessionStart` of that session (the dispatcher copies the visitors at post time). `ScriptedPromptFixture.make` gets a `hookVisitors:` parameter, in the pattern of `commandProviders:`.
    - The data directory uses the dotfolder name of the composition: `$XDG_DATA_HOME/<name>/hooks`. For the `acp-agent` CLI the name is `acp-agent`, thus the path is the path on the card.
  timestamp: 2026-10-19T22:14:12.105591+00:00
- actor: claude-code
  id: 01m5b4nncxmgfpssk6kg0k7bx0
  text: |-
    Implementation landed (not committed).

    Pins (Package.resolved is gitignored, the local file is updated): Hooks 2e29e38, Router f6af807 (coordinator request), Extras a63ddda, Multitool 7d63a26. FoundationModelsAgents also moved, f39d6a9 -> e059a9b: Agents f39d6a9 does not compile against Extras a63ddda (`switch must be exhaustive` on the new `MailSender.catalog`). Agents e059a9b removed `AgentsTool.agentNames`; three existing tests now read `launchableAgents().map(\.name)` (AgentEnvironmentTests, AgentsToolTests, SkillsMarketplaceTests).

    Production changes:
    - Package.swift: `FoundationModelsHooks` family dependency on main.
    - New `Agent/AgentHooks.swift`: `AgentHooks(dataDirectory:)` makes one `HookDispatcher`, one `SnapshotStore(<data>/snapshot)` and registers `SnapshotHook`. `AgentHooks.dataDirectory(name:environment:)` = `$XDG_DATA_HOME/<name>/hooks`, default `~/.local/share/<name>/hooks` (`acp-agent` for the CLI). `HookLineage.replacement(in:)`.
    - `RoutedACPAgent.init(... hooks: AgentHooks ...)` (required), `registerHookVisitors(_:)`.
    - `ComposedAgent.compose` makes the hooks and gives the dispatcher to `Router(hooks:)` / `EchoModel.makeRouter(hooks:)` and to the agent. `makeStubAgent` and IntegrationTests `LiveAgent` do the same (IntegrationTests not built here).
    - `CatalogContext.snapshotStore`; `ToolCatalog.makeRegistry` mounts `SnapshotsCapability(store:)`.
    - `makeBudgetedSession(hookLineage:)`; `applyModelSlot` gives `.replacement(in: sessionId)`.
    - `closeOpenSessions` awaits `hooks.dispatcher.drain()` after the teardown.
    - README Tools table: `snapshots` row.

    DECISION FOR THE REVIEWER: Router puts the tool hook layer (`Tool.sessionChecked`, internal) on the tools only in `LiveModelLoader`. The scripted backend calls its tools directly, so with `ScriptedModel` no `PreToolUse`/`PreToolResult`/`PostToolUse` fires and `SnapshotHook` takes no checkpoint (both tests failed for this reason, verified). The test target already uses `@testable import FoundationModelsRouter`; `HookCompositionTests` adds `HookLayeredLLMContainer`, which wraps the scripted tools with `sessionChecked` as `LiveModelLoader` does. If this use of an internal Router symbol is not acceptable, a Router card for a public seam is necessary (for example, Router puts the hook layer on the tools for each container, or a public `sessionChecked`).

    Tests: `swift test` 995 tests in 112 suites passed, 1 known issue (the existing withKnownIssue of HarnessSmokeTests), after the Router f6af807 update.
  timestamp: 2026-10-19T22:31:47.357292+00:00
- actor: claude-code
  id: 01m5b4nsdqjp4gb9qssbtftyka
  text: |-
    ### implement — changed
    - evidence: `swift test` 995 tests / 112 suites passed, 1 known issue (existing). New: Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift. Changed: Package.swift, RoutedACPAgent.swift, ComposedAgent.swift, Configuration/EchoModel.swift, Tools/CatalogContext.swift, Tools/ToolCatalog.swift, Agent/SessionSetup.swift, Agent/ConfigOptions.swift, Agent/SessionLifecycle.swift, README.md, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/.../Support/ScriptedPromptFixture.swift, ConnectionCloseTests.swift, AgentEnvironmentTests.swift, AgentsToolTests.swift, SkillsMarketplaceTests.swift, IntegrationTests/.../Support/LiveAgent.swift
    - next: /review; the reviewer decides on the HookLayeredLLMContainer test seam (internal `sessionChecked`).
  timestamp: 2026-10-19T22:31:51.479078+00:00
- actor: wballard
  id: 01m5b5bb2vhdd9e7x2b3hfpsfh
  text: 'Decision of the user (2026-10-19): keep the private HookLayeredLLMContainer and the @testable reach of Tool.sessionChecked in HookCompositionTests for now, so that this card can finish. Follow-up: Router card 01M5B5B3BVXQHZP8C14FK069KG adds a public scripted container with the tool hook layer to FoundationModelsRouterTestSupport, and ACP card 01M5B5B3QTYY3PVBQGXXVJMA9M then removes the private copy. A review finding about this reach is covered by those two cards.'
  timestamp: 2026-10-19T22:43:37.691563+00:00
- actor: claude-code
  id: 01m5b5j72x3yrhca4jrktk9byh
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 47e8ba7). 1 finding, 1 confirmed, 0 refuted. Finding: Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:243 `reuse/reuse` (the private `runPrompt` helper repeats the sequence of `CompactionReportTests.runPrompt` and `TelemetryContentSafetyTests.runPrompt`; move it into `ScriptedPromptFixture`).
    - card check: each item of Work is in the commit (Hooks dependency, `AgentHooks` with one dispatcher, one store and `SnapshotHook`, `Router(hooks:)`, `registerHookVisitors`, `SnapshotsCapability` in `ToolCatalog.makeRegistry`, `.replacement(in: sessionId)` in `applyModelSlot`, `hooks.dispatcher.drain()` after the teardown in `closeOpenSessions`). `HookCompositionTests` has one test for each acceptance criterion. `ScriptedPromptFixture.make(hookVisitors:)` calls `registerHookVisitors`. The changes past the card (the `AgentHooks` type, the data path from the dotfolder name, the required `hooks` parameter of `RoutedACPAgent.init` at all three construction sites, the `launchableAgents` test changes, the README `snapshots` row) gave no finding. The `HookLayeredLLMContainer` reach is covered by the user decision and the cards 01M5B5B3BVXQHZP8C14FK069KG and 01M5B5B3QTYY3PVBQGXXVJMA9M. The hook toolCallID is not changed in this package; Router owns it.
    - next: /implement the open finding, then review again.
  timestamp: 2026-10-19T22:47:22.973351+00:00
- actor: wballard
  id: 01m5b5jx57v87azy6j3x0pxmp5
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 19 files
    - test: green — swift test, 995 passed, 0 failed (run by implement after the Router f6af807 pin)
    - commit: 47e8ba7
    - review: findings — Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:243
  timestamp: 2026-10-19T22:47:45.575242+00:00
- actor: claude-code
  id: 01m5b5t30m31zzegfy1v29fq9z
  text: |-
    Finding `reuse/reuse` (HookCompositionTests runPrompt) is fixed. Not committed.
    - New `ScriptedPromptFixture.runPrompt(on:text:count:whileRunning:)` (Support/ScriptedPromptFixture.swift, beside `waitForPromptsFinished`). It sends the prompt, runs `whileRunning` (default: no work), waits for `count` idle updates, waits for `awaitPromptsFinished`, drains `agent.hooks.dispatcher`, and returns the collected updates (`@discardableResult`).
    - HookCompositionTests: the private `runPrompt` keeps only the update count before the prompt and `SkillsLibraryTests.toolCallText`, and calls the shared helper. The events test used the same send/wait sequence inline; it calls the shared helper now too.
    - CompactionReportTests: the private `runPrompt` is gone. No caller used its `(response, updates)` result. Each call site, and the inline send/wait sequence of `aCompactionWithNoPromptOpenReachesTheClient`, calls the shared helper.
    - TelemetryContentSafetyTests: the private `runPrompt` keeps only the count (`idleBefore + 1`) and passes `whileRunning` through as a closure.
    - The drain also runs for the compaction and telemetry suites. Each agent registers `SnapshotHook`, so the drain waits for snapshot work that is in progress. It does not change the result of those suites.
    - Tool note: `files edit file` with `replace_all: true` changed only one occurrence on each call here. Each call site needed its own edit.
    - Subtask boxes: all 5 acceptance criteria and the 2 test items are `[x]`. The review comment of commit 47e8ba7 found one HookCompositionTests test for each criterion, and `swift test` passes.
  timestamp: 2026-10-19T22:51:40.948017+00:00
- actor: claude-code
  id: 01m5b5tcr5p0fhc7ps96b4yrq8
  text: |-
    ### implement — changed
    - evidence: `swift test`: 995 tests in 112 suites passed, 1 known issue (the existing withKnownIssue of HarnessSmokeTests), 0 compiler warnings. 4 files: Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift, Tests/FoundationModelsACPAgentTests/CompactionReportTests.swift, Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift. Card: 8 of 8 boxes `[x]`, 0 open findings.
    - next: /review
  timestamp: 2026-10-19T22:51:50.917559+00:00
- actor: claude-code
  id: 01m5b5ytymw48p224hbtxcaga8
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a904427). 1 finding (1 confirmed, 1 refuted). Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:423 reuse/reuse. The prior finding HookCompositionTests.swift:243 reuse/reuse is checked.
    - next: Make ResumeSessionFixture.runPrompt call ScriptedPromptFixture.runPrompt, or extend the shared helper so the resume fixture can use it. If the return types cannot agree, write a doc comment that tells why the resume path keeps its own copy.
  timestamp: 2026-10-19T22:54:16.532901+00:00
- actor: wballard
  id: 01m5b5zgcysam9ejhsb1da6gp8
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 4 files (shared ScriptedPromptFixture.runPrompt)
    - test: green — swift test, 995 passed, 0 failed
    - commit: a904427
    - review: findings — Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:423 (prior HookCompositionTests.swift:243 checked)
  timestamp: 2026-10-19T22:54:38.494831+00:00
- actor: claude-code
  id: 01m5b639npchcs6rwpe640t7k4
  text: 'Research for the finding ScriptedPromptFixture.swift:423 `reuse/reuse`. The send / idle-wait / prompts-finished sequence has more copies than `ResumeSessionFixture.runPrompt`. Copies found: ResumeSessionFixture.runPrompt, PromptExecutionTests (3 sites), ConfigOptionsTests (3 sites), UserPresenceTests (2), TranscriptLocationOverrideTests, TranscriptFidelityTests.drivePrompt, SessionHistoryTests, ConnectionCloseTests, SessionSurfaceLoggingTests, AgentReleaseTests, RequestTracingTests, CancellationTests. Three of them need what the shared helper does not give now: the PromptResponse (ResumeSessionFixture, SessionHistoryTests), a request that the test builds (RequestTracingTests `_meta`, the private makePromptRequest of PromptExecutionTests and CancellationTests), and a harness with no fixture or a second session (TranscriptLocationOverrideTests, TranscriptFidelityTests). Plan: the shared helper takes a PromptRequest and a harness and returns a `PromptRun` (response + updates). A text overload on the fixture calls it. Not copies (no idle wait, or the idle is of a later mail): MailDeliveryPauseTests, PromptFollowUpTests, BuiltinCommandsTests and CompactionReportTests `/compact` gate sites, CancellationTests multi-session site.'
  timestamp: 2026-10-19T22:56:42.678765+00:00
- actor: claude-code
  id: 01m5b6adgabxr011ee63wvnyzv
  text: |-
    Finding ScriptedPromptFixture.swift:423 `reuse/reuse` is fixed. Not committed.
    - The shared helper is now one sequence: `ScriptedPromptFixture.runPrompt(_ request:through harness:count:whileRunning:)`. It sends the request, runs `whileRunning`, waits for `count` idle updates, waits for prompts-finished of `request.sessionId`, drains the hook dispatcher, and returns `PromptRun` (`response` + `updates`). `runPrompt(on:text:count:whileRunning:)` builds the request and calls it. `count` has the default 1.
    - The return types agree: `PromptRun` carries the PromptResponse, so no doc-comment exception was necessary. `ResumeSessionFixture.runPrompt` now calls the shared helper and returns `.response`.
    - Other copies of the send / idle-wait / prompts-finished sequence now call the helper: PromptExecutionTests (3 sites; the two-prompt cancel proof uses `whileRunning`; the repetition proof waits for the journal after the helper), ConfigOptionsTests (3), UserPresenceTests (2), SessionHistoryTests (uses `.response`), ConnectionCloseTests, AgentReleaseTests, RequestTracingTests (request with `_meta`), TranscriptLocationOverrideTests (harness with no fixture), TranscriptFidelityTests.drivePrompt (second session; waitForRecordedResponses after the helper), SessionSurfaceLoggingTests and CancellationTests (cancel in `whileRunning`). The callers of the old return type (HookCompositionTests, CompactionReportTests) read `.updates`.
    - Not copies, so not changed: MailDeliveryPauseTests, PromptFollowUpTests, BuiltinCommandsTests and CompactionReportTests `/compact` gate sites (no idle wait), CancellationTests multi-session proof (the idle is of the other session).
    - The drain now also runs for these suites. It only waits for hook work in progress; the full suite stays green.
    - Tool note: `kanban move task` / `update task` / `add comment` return the full board (more than 70k characters) here.
  timestamp: 2026-10-19T23:00:35.978648+00:00
- actor: claude-code
  id: 01m5b6ajnjke22vcknda74pb73
  text: |-
    ### implement — changed
    - evidence: `swift test`: 995 tests in 112 suites passed, 1 known issue (the existing withKnownIssue of HarnessSmokeTests), 0 compiler warnings. 15 test files: Support/ScriptedPromptFixture.swift, Support/ResumeSessionFixture.swift, HookCompositionTests.swift, CompactionReportTests.swift, PromptExecutionTests.swift, ConfigOptionsTests.swift, UserPresenceTests.swift, SessionHistoryTests.swift, ConnectionCloseTests.swift, AgentReleaseTests.swift, RequestTracingTests.swift, TranscriptLocationOverrideTests.swift, TranscriptFidelityTests.swift, SessionSurfaceLoggingTests.swift, CancellationTests.swift. Card: 9 of 9 boxes `[x]`, 0 open findings.
    - next: /review
  timestamp: 2026-10-19T23:00:41.266649+00:00
position_column: doing
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
- [x] A new session, one prompt with a tool call that writes a file, then a close: a recording visitor added with `registerHookVisitors` gets `SessionStart`, `PrePrompt`, `PreToolUse`, `PreToolResult`, `PostToolUse`, `PostPrompt` and `SessionEnd`, all with the ACP session id as `sessionKey`.
- [x] After a model-slot switch, the replacement session has the same `sessionKey`, and `origin: .replacement`.
- [x] A resumed session gets `SessionStart(.resumed)` with the ACP session id as `sessionKey`.
- [x] In a temporary git work tree, a tool call that writes a file, then `dispatcher.drain()`, then `list snapshots` through the session's Multitool: one checkpoint. Then `undo snapshot` restores the file.
- [x] When the connection ends, `closeOpenSessions` returns only after the dispatcher drained.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift` (Swift Testing, `@Suite(.closesHarnesses)`): each criterion above, with `AgentClientHarness` and `ScriptedModel` from `FoundationModelsACPAgentTestSupport`. Call `dispatcher.drain()` before each assertion on post events or on snapshots, because they are async.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks

## Review Findings (2026-10-19 17:44)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 7 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift:243` `reuse/reuse` — The new private static runPrompt helper repeats the send, wait, drain, and text-extraction sequence that CompactionReportTests.runPrompt and TelemetryContentSafetyTests.runPrompt already implement. The shared shape belongs in ScriptedPromptFixture, beside waitForIdle and waitForPromptsFinished, so one canonical version serves all suites. Move the shared sequence into ScriptedPromptFixture as a static helper that takes the fixture, the text, and the count, and returns the updates. Have HookCompositionTests, CompactionReportTests, and TelemetryContentSafetyTests call it. Keep each suite's extraction of its own text (toolCallText) in that suite, or pass it as a closure.

## Review Findings (2026-10-19 17:52)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift:423` `reuse/reuse` — The new shared `ScriptedPromptFixture.runPrompt` repeats the prompt, idle-wait and prompts-finished sequence of `ResumeSessionFixture.runPrompt`, which already exists. The change adds a parallel copy instead of extending or routing through the existing helper, so two prompt-run paths now have to be kept in step. Make `ResumeSessionFixture.runPrompt` call `ScriptedPromptFixture.runPrompt`, or extend the shared helper so the resume fixture can use it. If the return types cannot be reconciled, state in a doc comment why the resume path keeps its own copy. This is a judgment call: the drain step may be the deliberate difference.
