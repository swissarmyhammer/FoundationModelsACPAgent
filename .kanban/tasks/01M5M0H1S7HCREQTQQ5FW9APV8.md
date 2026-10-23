---
assignees:
- claude-code
depends_on:
- 01M5KW1TKC9N9DGCZG5W53XMHK
position_column: todo
position_ordinal: '8380'
title: Resumed sessions and model-switch replacements join the shared per-cwd snapshot timeline
---
Split from ^w53xmhk (2026-10-23). Two gaps left after ^w53xmhk:

1. Resume: Router `restoreSession` / `restoreSessionTree` take no hook session key, so a resumed session uses its own id as key, not the cwd key. Asked the Router session for a `hookSessionKey` parameter passed to the restored root's `makeSessionHooks(requestedKey:)`. Then SessionResume.swift passes `HookLineage(workingDirectory:, origin: .resumed)` and the existing resume test flips to the cwd key.
2. Model switch: the replacement session gets a new Router id that `SnapshotSessionKeys` does not know. Checkpoint owners are Router session ids (HookSession.sessionID), so after the replaced session is released the change feed records nothing under the ACP session id for checkpoints the replacement makes. Map the replacement's Router id to the ACP session (or make the owner the ACP session id).

## Do
- [x] Update the Router pin to the sha that adds the restore hook key; resume passes the cwd key. (Done in ^w53xmhk round 2, 7bba627, Router 7c07fb29.)
- [ ] Model-switch replacement: its checkpoints reach the ACP session's change feed and show the ACP session as owner.

## Tests (first)
- Resume a session in a cwd where another session is open: both share one timeline.
- After a model switch, a take by the replacement appears as a change for the ACP session id. #share-per-cwd