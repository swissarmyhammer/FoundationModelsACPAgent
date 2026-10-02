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
position_column: todo
position_ordinal: '8180'
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