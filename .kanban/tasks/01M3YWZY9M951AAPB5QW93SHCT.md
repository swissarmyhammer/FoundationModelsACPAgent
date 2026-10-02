---
assignees:
- claude-code
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