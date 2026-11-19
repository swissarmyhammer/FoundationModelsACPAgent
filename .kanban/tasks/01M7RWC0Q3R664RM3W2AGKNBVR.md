---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rx2tge7cpjhp0vtsp10qve
  text: 'Dependency available (2026-11-18): Router ^1vesqjj is on origin/main at de36cd24. Removed public API: `SessionTreeRestorationError.notARootSession`, `RestoredSessionTree.session(_:)` and `RestoredSessionTree.children(of:)`. I checked: this package does not use them (the `children(of:)` calls in the tests are on this package''s own `SessionTree`), so the build does not break. Restore a fork only by its own id; a fork that the directory holds does not move on a model switch, so move it with a restore by its id. This task still waits for Router ^vhy7017 (the launcher operation).'
  timestamp: 2026-11-19T03:19:55.662902+00:00
depends_on:
- 01M7QV7TASP791JZFKKEMD9F4N
position_column: todo
position_ordinal: '9180'
title: 'D205: build a fork through the Router launcher operation, and adopt the root-only restore'
---
Follow-up of ^emd9f4n (2026-11-18). Answers of the Router session to two questions about the fork.

## Dependencies (not on this board; start when the Router sends the shas)

- Router ^vhy7017 (01M7RWB7YTPYSWRXZJAVHY7017): a new `SessionLauncher` operation for a fork. `RouterSessionDirectory.fork(_:)` calls it with the source id, the cut position and the fork id, so the host builds the fork with its own surface. Only then does the directory register the fork and mail the first prompt. A default implementation keeps today's behavior. The Router sends the exact signature.
- Router ^1vesqjj: `restoreSession(id:)` of a root restores the root ONLY: no session, no directory entry and no hooks for a fork under it. A fork is restored only by its own id. With `switchingModel`, a recorded fork that has no session moves on disk with one `modelChanged` event; a fork that the directory holds (live or suspended) does not move, and the host moves it with a restore by its id. A run of a fork is claimed only with a restore by the fork id (a claim through the root throws `runNotClaimable`). `SessionTreeRestorationError.notARootSession` is removed.

## Current behavior (from ^emd9f4n, commit 8447ce3)

- A fork from the `sessions` tool stays live in the Router on the tools of the source until a client resumes it, and a first prompt runs on the surface of the source. On `session/resume`, the agent stops the live Router fork and restores it on its own surface (`Agent/SessionForkRestore.swift`), which can cancel that first prompt.
- A cold resume of a source restored its recorded forks with it, which could make a second live instance of a fork that the agent holds.

## Change

1. Implement the new launcher operation in this agent's `SessionLauncher`: build the fork with this agent's surface (the MCP servers and directories of the request, or none when the request omits them, per the ACP spec decision on ^emd9f4n; the agent of the source), so the agent holds the fork from its start.
2. Remove the stop-and-restore path for a tool fork (`SessionForkRestore.swift`), if the launcher makes it unnecessary.
3. Adopt the root-only restore: remove each use of `SessionTreeRestorationError.notARootSession`; restore a fork only by its own id; move a fork that the agent holds on a model switch with a restore by its id; claim a run of a fork only through its id.
4. Update README.md and ARCHITECTURE.md.

## Tests

- A `fork session` from the tool with a first prompt: the prompt runs on the surface of this agent, and no resume cancels it.
- A cold resume of a source does not make a second live instance of a fork that the agent holds.
- A model switch of a source with a fork that the agent holds moves the fork through a restore by its id.
- A run of a fork is claimed by the fork id. #d205 #fork