---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yzb21xjsavqffwnjstcfw6
  text: 'Upstream confirmed (FoundationModelsACP session, 2026-10-02): carded there as ^jd4740x, with the proposed fix (take and clear in one lock, Connection.swift:28). It also covers an append after runAll(): the closure runs at once or is dropped with a warning, never kept. Tests use a weak reference while a child task is alive. Order there: ^rpc6wrp (insertUserMessage helper, in review), then ^jd4740x. They will send the commit when pushed; then move the pin and confirm AgentReleaseTests still passes.'
  timestamp: 2026-10-02T18:52:01.981801+00:00
- actor: claude-code
  id: 01m3z0n09cyp1na8bx5eek2t7m
  text: 'Upstream fixed (FoundationModelsACP ^jd4740x, main 4ccc130): runAll() takes and clears the closures in one lock; a closure added after runAll() started is DROPPED with a warning ("Connection: dropped work deferred for request <id>: ..."); if the connection closes while the handler runs, dispatchRequest calls discardAll() and releases the closures. insertUserMessage uses the same hooks: call it on the handler''s own task, not a child task. Our weak captures are now not necessary but harmless. Done when: the pin moves past 4ccc130 (with ^hkr6ykz) and AgentReleaseTests still passes; also check that no code of ours adds a response hook from a child task, because such work is now dropped.'
  timestamp: 2026-10-02T19:14:56.428152+00:00
- actor: claude-code
  id: 01m3z95d03deagk3ngj0r4gndv
  text: |-
    Check after the move of the pin to FoundationModelsACP e14d853 (done in the work of ^hkr6ykz).

    Result: AgentReleaseTests passes. All three tests pass in the serial run (`swift test --no-parallel`), and the full suite passes with 721 tests in 81 suites.

    No code of ours adds a response hook from a child task. Each call of `afterRespondingToCurrentRequest`, `afterRespondingInCurrentServiceContext` and `insertUserMessage` runs synchronously in the handler of a request:
    - `SessionSetup.publishAvailableCommands`: in the `session/new` and `session/resume` handlers, through `activateSession`.
    - `PromptExecution.scheduleModelPrompt`: `insertUserMessage` runs before the deferred work of the prompt is registered, in the `session/prompt` handler.
    - `PromptExecution.endTelemetryAfterPrompt`: in the `session/prompt` handler.
    - `CommandDispatch` `.action` case: `insertUserMessage` and then `afterRespondingInCurrentServiceContext`, in the `session/prompt` handler.
    - `RequestTracing`: in the handler that it wraps.

    Finding: the new history sink holds the agent and the connection weakly. Before, the sink of the terminal projection held the connection strongly, and that kept the agent alive. Now the agent of a test that does not close its session goes when the test ends. A session that mounts an MCP server then releases its `SurfaceRefresher` while the watch task runs, and the Multitool debug assertion stops the process (`SurfaceRefresher.swift:136`). `ScriptedPromptFixture.close()` now sends `session/close` for each session before it closes the wire. Production has the same gap: no upstream hook tells the agent that its connection closed, so a host that drops the connection without `session/close` gets the assertion in a debug build.
  timestamp: 2026-10-02T21:43:42.339038+00:00
- actor: claude-code
  id: 01m3zbd86nk8f31hgsm72yghpf
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (15c3183) gave 0 findings, 0 confirmed, 0 refuted. The 4 changed files are in `.kanban/`, and `.reviewignore` excludes them. No prior `## Review Findings` section is on the card.
    - Criterion 1: Package.resolved pins FoundationModelsACP at e14d853. 4ccc130 is an ancestor of e14d853. The comment of 2026-10-02 21:43 records that AgentReleaseTests passes.
    - Criterion 2: I read each call site of `afterRespondingToCurrentRequest`, `afterRespondingInCurrentServiceContext` and `insertUserMessage` in Sources/. Each one runs synchronously on the task of the request handler. No call site is in a `Task {}`, a `Task.detached` or a task group:
      - SessionSetup.publishAvailableCommands: called from activateSession. newSession and resumeSession call activateSession in `RequestTracing.withEnteredRequestSpan`. That function runs its body inline through `ServiceContext.withValue` and `TracedCall.run` with a `nonisolated(nonsending)` body.
      - PromptExecution.endTelemetryAfterPrompt: called directly in `prompt(_:)`.
      - PromptExecution.scheduleModelPrompt (insertUserMessage, then afterRespondingInCurrentServiceContext): called from acceptPrompt and from the `.modelPrompt` case of dispatchCommand. Both run in `prompt(_:)` in `ServiceContext.withValue`.
      - CommandDispatch `.action` case (insertUserMessage, then afterRespondingInCurrentServiceContext): called from acceptPrompt.
      - RequestTracing.afterRespondingInCurrentServiceContext and SessionHistory/SessionSetup.insertUserMessage: wrappers. They run on the task of the caller.
      - The `Task {}` sites in Sources/ (OwnedSelectionSession, ProbeTimeout, TerminalStream, ElicitationRelay, PromptExecution idleWait, SessionFollowUp, BuiltinCommands, CommandRegistry) do not call these APIs.
    - next: none. The card is in done.
  timestamp: 2026-10-02T22:22:56.725850+00:00
- actor: claude-code
  id: 01m3zbdsd6z1yceqasam0aqabb
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — the checks ran in the work of ^hkr6ykz (comment of 2026-10-02 21:43); the pin is at e14d853, after 4ccc130
    - test: green — AgentReleaseTests passes; swift test 721 tests in 81 suites (recorded on ^hkr6ykz)
    - commit: 15c3183 (kanban only)
    - review: clean — 0 findings; criterion 2 confirmed by reading each call site
  timestamp: 2026-10-02T22:23:14.342536+00:00
position_column: done
position_ordinal: ff9280
title: 'Report upstream: FoundationModelsACP ResponseHooks keeps each deferred closure after it ran, through the task-local that child tasks inherit'
---
## Problem

`Connection.dispatchRequest` binds a new `ResponseHooks` into the task-local `Connection.currentResponseHooks` around the request handler. `AgentSideConnection.afterRespondingToCurrentRequest(_:)` appends each closure to it, and `ResponseHooks.runAll()` runs them after the response. `runAll()` reads the array but does not clear it.

Each unstructured `Task {}` that the handler starts inherits the task-local value, thus it keeps the `ResponseHooks` object, and with it every closure and every value the closures captured, for the life of that task. In this agent, `session/new` starts the skills watcher (Skills `EventBroadcaster`), which lives on. `leaks --traceTree` on 2026-10-02 showed: `CommandRegistry` <- hook closure <- `ResponseHooks` <- task <- Skills `EventBroadcaster` continuation. That kept a Router session and the resident models of a closed agent in the model pool of the process (task ^173qn8n). This repo now captures weakly in its hooks, but each other user of the API can hit the same retention.

## The upstream change

In `FoundationModelsACP/Connection/Connection.swift`, make `runAll()` take the closures out of the array before it runs them:

```swift
func runAll() async {
    let work = hooks.withLock { hooks in
        let taken = hooks
        hooks = []
        return taken
    }
    for item in work { await item() }
}
```

Optionally, also refuse an `append` after `runAll()` started, because no response follows it.

## Done when

- The change is in FoundationModelsACP with a test that a closure registered through `afterRespondingToCurrentRequest` is released after it ran, also when a task that the handler started is still alive.
- This repo moves its pin, and `AgentReleaseTests` still passes. #upstream