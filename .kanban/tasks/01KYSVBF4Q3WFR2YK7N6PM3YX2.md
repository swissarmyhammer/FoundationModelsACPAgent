---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1jk8s12s9633d1sw4peknt6
  text: |-
    ### research — findings

    - The close/delete stubs are in RoutedACPAgent.swift (`closeSession`, `deleteSession` both call `refuseUnimplemented`). The task moves the real handlers into Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift.
    - `markSessionClosed(_:)` is in Agent/PromptTurn.swift. It sets `isClosed` and finishes the shell output stream. Seven test files call it. The real close path can call it as one step.
    - `ActiveSession` (Agent/SessionSetup.swift) already carries `surface: SessionSurface` with `serverPool`, `shellOutput`, `filesReadVerb`. The pool already holds each spawned `StdioServerProcess` (ToolCatalog.makeRegistry adds each one) and the attached `SurfaceRefresher` (MCPComposition.startSurfaceRefresher). `MCPServerPool.shutdownAll()` stops the refresher first, then disconnects servers, then shuts each subprocess down.
    - `RoutedSession.close()` (Router checkout) finishes every `streamSessionEvents()` subscription, sweeps the mailbox, and journals terminal events. It is idempotent. It does not close descendants; the package must track them. `ActiveSession` gets a `descendants` list and the agent gets `adoptDescendant`, so a fork is released at close and the path stays open for spawned sessions.
    - `TurnStateOwner` (Agent/TurnState.swift) has no wait for the turn end. The close path needs one: `turnDidEnd` resumes waiters after the idle update went out, so the close response follows `idle(cancelled)`.
    - The wire notifications dispatch in read order (`Connection.dispatchSingle` awaits `notificationHandler`), so the ordering assertion "idle(cancelled) before the close response" is deterministic in the harness.
    - `SessionIndex` is append-only with no removal. Delete adds `removeRecords(sessionId:)`: read, filter, atomic rewrite.
    - `DeleteSessionRequest` carries only `sessionId` (no cwd). A session not in the table is found through `ProjectRegistry` + per-project `loadSessionContext(...).transcriptRoot`, the same walk `session/list` makes. The id is treated as a path segment only after a ULID parse, so no path traversal.
    - Test support: `ScriptedTurnFixture` (scripted turns, `.hold` step for a long turn), `ResumeSessionFixture` (real recorded transcripts, fork-capable backend), `BuiltProductLocator.mcpTestServerURL()` for a stdio server spawn, `pgrep -f` reap pattern in Integration/ClientServerTests. The process test copies the server binary to a unique path so a parallel suite cannot match.
    - `SessionDeleteCapabilities()` is already advertised in Agent/Initialization.swift.
    - Validators read: Swift rule set (casing, optionals, guard-first, no magic numbers, docs on each item, functions under 250 lines), duplication + reuse, completeness, test-integrity. The delete path validates the id before it forms a path.
  timestamp: 2026-09-03T02:58:47.458688+00:00
- actor: claude-code
  id: 01m1jkvcjsqxcsyh6yx34ckejr
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift (new: close, delete, adoptDescendant, disk removal), Sources/FoundationModelsACPAgent/Agent/TurnState.swift (waitForTurnEnd), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift (ActiveSession.descendants), Sources/FoundationModelsACPAgent/Transcripts/SessionIndex.swift (removeRecords), Sources/FoundationModelsACPAgent/Agent/SessionList.swift (registryUserLayerRoot made internal for reuse), Sources/FoundationModelsACPAgent/RoutedACPAgent.swift (removed the close/delete stubs and the now-unused refuseUnimplemented). New tests: Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift (10 cases).
    - close calls RoutedSession.close() (the sweep), then closes descendants, finishes the shell stream, and shuts the pool down after the sweep. deinit does not sweep. A close during an active turn cancels the turn and waits for idle(cancelled) before the response.
    - delete closes an active session first, removes the transcript directory and the sessions.jsonl line; a non-ULID or absent id is silent success. Resume of a deleted session fails naturally.
    - next: TEST
  timestamp: 2026-09-03T03:08:57.305482+00:00
- actor: claude-code
  id: 01m1jkwnmm0g1mtzrdhxsgytcr
  text: |-
    ### commit — changed
    - evidence: 7857a5a feat(agent): session/close and session/delete tree teardown and real removal
    - next: REVIEW
  timestamp: 2026-09-03T03:09:39.348347+00:00
- actor: claude-code
  id: 01m1jm5grxb82e1pjqnkemsh3d
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift:13 (code-hygiene/idioms-swift redundantSwiftTestingSuite: remove the redundant @Suite attribute with no arguments)
    - next: fix the finding, then TEST, COMMIT, REVIEW again
  timestamp: 2026-09-03T03:14:29.277449+00:00
- actor: claude-code
  id: 01m1jm5q4ccfga3722m87npskt
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 sources + 1 new test file (SessionLifecycle.swift, TurnState.waitForTurnEnd, ActiveSession.descendants, SessionIndex.removeRecords, SessionList.registryUserLayerRoot internal, RoutedACPAgent stubs removed).
    - test: green — swift test 332 tests / 37 suites, 0 failed, 1 expected known issue; swift build --build-tests no code warnings.
    - commit: changed — 7857a5a.
    - review: findings — 1 finding at SessionLifecycleTests.swift:13 (code-hygiene/idioms-swift redundantSwiftTestingSuite).
    - outcome: findings open; go to iteration 2.
  timestamp: 2026-09-03T03:14:35.788874+00:00
depends_on:
- 01KYSVA96FDQP14HPP38ZQ362W
- 01KYSVB1ACAR7NDK06015S796H
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-09-02 22:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

- [ ] `Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift:13` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.