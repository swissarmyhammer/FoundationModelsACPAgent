---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qvmqf6fkheqecttg6hma7t
  text: |-
    Dependency available (2026-11-18): FoundationModelsACP session/fork is on main at cb9aee7. Run `swift package update FoundationModelsACP` when this task starts.
    - Serve: implement `Agent.forkSession(_ ForkSessionRequest) async throws -> ForkSessionResponse`. The default answers method-not-found. `AgentSideConnection` dispatches it. NAME CHANGE: the handler is `forkSession`, not `sessionFork`.
    - Read the cut: `SAH.ForkCut.extract(from: params.meta)` gives `messageId` (the ACP message id in the source transcript) and `side` (`.before` / `.after`). An unknown side decodes with its raw text: refuse it with invalid params. No cut means the last completed turn.
    - Announce: `SessionCapabilities(fork: SessionForkCapabilities(meta: try SAH.ForkCut.advertise(into: nil)))` sets `fork` and `_meta.sah.forkCut = true`.
    - Add a test: an unknown `side` gives invalid params.
    This task can start. It still must not announce `fork` in a pushed build before ^emd9f4n works.
  timestamp: 2026-11-18T17:35:30.790265+00:00
position_column: todo
position_ordinal: '8e80'
title: 'D205: announce session/fork with the forkCut flag; map an ACP message id to a history position'
---
Decision D205 in `TestudoApp/features/decisions.md` (commit 483664d). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/fork/acpa-brief.md`, changes 1 and 2. Overview: `overview.md` in the same folder.

## Dependency

FoundationModelsACP on `main` (`acp-brief.md`): `ForkSessionRequest`, `ForkSessionResponse`, `SessionForkCapabilities`, `SessionCapabilities.fork`, the `sessionFork` route and the `SAH.ForkCut` helper for `_meta.sah.forkCut`. Not on this board: do not start until the ACP sha comes.

## Current state

1. The agent serves `initialize`, `session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`, `session/cancel`, `session/delete` and `session/set_config_option` (`Sources/FoundationModelsACPAgent/RoutedACPAgent.swift:640-652`). It does not serve `session/fork`.
2. The session capabilities are announced in `Agent/Initialization.swift:125` (`SessionCapabilities(...)`). The capability set of a session is in `Agent/SessionCapabilitySet.swift`.
3. The lifecycle handlers are in `Agent/SessionLifecycle.swift` (for example `closeSession(_:)` at line 23; the order and permission checks of `session/delete` at lines 82-83).
4. The ACP history of a session, with the `messageId` of each user and agent message, is in `Agent/SessionHistory.swift` (for example lines 87 and 469-477).

## Change

1. Add `fork: SessionForkCapabilities` with the flag `_meta.sah.forkCut = true` to the session capabilities of `initialize`.
2. Add the `sessionFork` route and handler, with the same order and permission checks as the other session methods.
3. Read the cut from `_meta.sah.forkCut`. With no cut, the cut is `.lastCompletedTurn`. With a cut, map the ACP message id to a history position of the source (`.historyPosition(n)`): `after` is the position after the end of that message; `before` is the position before it.
4. Keep a map from message id to history position in the session history, or compute it from the recorded history. It must also work for a session that was resumed after a restart.
5. An unknown message id is an invalid-params error, and no fork is made.
6. Until the Router fork is on `main`, the handler can stop after the cut is mapped (the fork call is ^ next task). Do not announce `fork` to clients in a pushed build before the fork works: keep the capability behind the same commit as the Router call, or push both tasks together.

## Tests

- `initialize` announces `fork` with the cut flag.
- The map: `after` the agent message of turn 1 gives the position after turn 1; `before` the user message of turn 2 gives the same position; this also works after a resume from disk.
- An unknown message id gives invalid params. #d205 #fork