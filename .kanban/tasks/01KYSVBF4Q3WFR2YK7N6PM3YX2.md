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
Plan.md §10. In `Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift`:

- `session/close` (MUST semantics): cancel the session's work as if `session/cancel` had been called — pending permissions answered cancelled; a close during an active turn sends `state_update: idle` + `stopReason: "cancelled"` **before** the close response. Then release: in-flight MCP calls, detached work, spawned stdio server processes, and the session's **descendants** (forks and agent spawns — no orphan burning a model gate). Recording closes; the transcript stays on disk. Closed sessions remain listable and resumable.
- `session/delete` (capability-gated; we advertise it): a **real delete** — remove `<cwd>/.<name>/transcripts/<sessionId>/` and its `sessions.jsonl` entry. Active session: close first (full §10.1 semantics), then delete. Already-deleted / never-existent → silent success. Docs and response must not claim committed git history is unrecoverable (§10.2 honesty note).

- [ ] Close = cancel semantics + resource release incl. descendants
- [ ] idle(cancelled) before close response on active turns
- [ ] Delete removes directory + index entry
- [ ] Close-then-delete for active sessions; silent success on absent

## Acceptance Criteria
- [ ] Closing a session mid-scripted-turn: collector sees idle(cancelled) before the close response resolves; the transcript directory survives
- [ ] After close, `session/resume` on that id still works
- [ ] After delete, the directory and the index line are gone, and resume errors
- [ ] Deleting a nonexistent sessionId succeeds

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionLifecycleTests.swift` — harness; filesystem-truth assertions on the transcript directory and index
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.