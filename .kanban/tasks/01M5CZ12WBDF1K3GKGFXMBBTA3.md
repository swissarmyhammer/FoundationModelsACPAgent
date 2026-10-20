---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'ACPA-15: session/delete removes the snapshot timeline of its session'
---
## What
ACPA-15 and D96(b): Archive of the app removes the timeline of the session. The user decided on 2026-10-20 that Archive is the existing `session/delete`. The user also decided that there is NO sweep of orphan timelines at start (many sessions can share a folder). The explicit command of card ^5ynrv0z removes orphans.

Now `deleteSession` (`Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift:44`) removes `<root>/<ULID>/` and the `sessions.jsonl` record, but it never calls `SnapshotStore.remove(sessionKey:)`. The session key is the ACP session id (`HookLineage`, `AgentHooks.swift:98-117`).

Do this in `deleteSession`:
1. If the session is open, end it first as `session/close` does (`tearDownSession`, line 144), so the `SnapshotHook` gets `SessionEnd` and releases the key. Drain the hook dispatcher so the release is done before the remove.
2. Call `hooks.snapshotStore.remove(sessionKey: <session id>)`.
3. If it throws `SnapshotError.sessionKeyOpen`, another session still has the key. Keep the timeline, log one line at notice level with the key only, and complete the delete with success.
4. Any other error: log it (key and error case only, no paths with content) and complete the delete with success. A missing directory is not an error (HOOKS-4).

Do not add a removal to agent start or to `session/close`.

## Acceptance Criteria
- [ ] After `session/delete`, the shadow folder of the session key does not exist.
- [ ] When another owner has the key open, `session/delete` succeeds and the shadow folder stays.
- [ ] `session/close` and agent start keep the shadow folder.
- [ ] The logs name only the key and the error case.

## Tests
- [ ] A test: new session, one turn that writes a file (a checkpoint exists), `session/delete`, then `shadowSessionKeys()` does not have the key.
- [ ] A test: open the key with a second owner on the same `SnapshotStore`, `session/delete`, the delete succeeds and the key stays.
- [ ] A test: `session/close` keeps the key.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-15