---
assignees:
- claude-code
depends_on:
- 01KYSVA96FDQP14HPP38ZQ362W
- 01KYSVB1ACAR7NDK06015S796H
position_column: todo
position_ordinal: '9080'
title: 'session/close and session/delete: tree teardown and real removal'
---
## What
Plan.md §10. Work in `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift`.

`session/close` (MUST semantics):

- Cancel the session's work as if `session/cancel` had been called. A close during an active turn sends `state_update: idle` with `stopReason: "cancelled"` before the close response.
- **Call `RoutedSession.close()`.** It runs the mailbox sweep: it cancels every background run, rejects every pending elicitation, journals the terminal events, and finishes every `streamSessionEvents()` subscription. It is idempotent.
- **`deinit` does NOT run that sweep.** You must call `close()`. Dropping the session leaks background runs and leaves subscriptions open.
- Then release our own resources: the session's descendants (forks and agent spawns, so no orphan holds a model gate), and the MCP servers. **Agent spawns do not occur in this iteration** (plan.md §11.3). Release forks now. Keep the descendant path open for spawned sessions, which a later Multitool agents capability will start as background runs; the sweep in `close()` already cancels every background run, so a spawned run will fall under it.
- **Shut the MCP servers down in this order: the session sweep first, then `MCPServerPool.shutdownAll()`.** The pool already holds every server that `withMCP(servers:)` recorded, reachable as `Builder.serverPool`. Add each `StdioServerProcess` the session spawned to the pool as well.
- If the session attached a `SurfaceRefresher`, stop it. It asserts in `deinit` if it is released while its watch task still runs. Attaching it to the pool is enough, because `shutdownAll()` stops it.
- Recording closes. The transcript stays on disk. A closed session stays listable and resumable.

`session/delete` (capability-gated; we advertise it):

- A real delete. Remove `<cwd>/.<name>/transcripts/<sessionId>/` and the `sessions.jsonl` entry.
- For an active session, close first with the full semantics above, then delete.
- An already-deleted or never-existent id gives silent success.
- Do not claim in the docs or the response that committed git history is unrecoverable (§10.2).

- [ ] Close calls `RoutedSession.close()` and does not rely on deinit
- [ ] `idle(cancelled)` precedes the close response on an active turn
- [ ] Descendants released
- [ ] `MCPServerPool.shutdownAll()` after the session sweep; refresher stopped
- [ ] Delete removes the directory and the index entry
- [ ] Close-then-delete for an active session; silent success when absent

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/close` with an unknown `sessionId` gives JSON-RPC invalid params (`-32602`) with the id in `data`. A known but already-closed session gives success `{}`; close is idempotent. `session/delete` keeps silent success for unknown and already-deleted ids.

## Acceptance Criteria
- [ ] `session/close` on an unknown id gives `-32602` with the id in `data`; a second close of the same known session gives `{}`
- [ ] Closing a session during a scripted turn makes the collector see `idle(cancelled)` before the close response resolves, and the transcript directory survives
- [ ] After close, `session/resume` on that id still works
- [ ] After close, a `streamSessionEvents()` subscription taken before the close finishes
- [ ] After close, no spawned stdio server process remains
- [ ] After delete, the directory and the index line are gone, and resume gives an error
- [ ] Deleting an unknown sessionId succeeds

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift` — harness, with filesystem-truth assertions on the transcript directory and the index, and a process check after close
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.