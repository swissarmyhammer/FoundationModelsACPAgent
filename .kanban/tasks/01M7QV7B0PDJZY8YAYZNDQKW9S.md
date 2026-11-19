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
- actor: claude-code
  id: 01m7rwm4ahtekg3jyavyncgmwt
  text: |-
    ### review — findings
    - evidence: run 1, `review sha c912570~1..c912570`: 1 finding (1 confirmed, 0 refuted, 0 failed) — Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:135. Run 2, `review sha 847d966~1..847d966`: 0 findings (0 failed).
    - next: Correct the finding in Sources/FoundationModelsACPAgent/Agent/SessionFork.swift. Then review the task again.
  timestamp: 2026-11-19T03:11:54.193755+00:00
- actor: claude-code
  id: 01m7rxas9pwj9fnqtp64npz8g3
  text: |-
    Finding SessionForkHandler `invariant-propagation` (SessionFork.swift): HEAD 8447ce3 already gave the full recipient set at the call site, but `forkPoint(of:in:sessionId:recipients:)` still had the default `recipients ?? [sessionId]`, so a caller could count the turns with the source id only. That default was the same cause. Fix:
    - `forkPoint(of:in:sessionId:)` now takes a `ForkSourceHistory` (the history and its recipients as one value), and maps the message with the new `ForkSourceHistory.turn(holding:)`. Thus each turn count of the source (`end(of:)`, `isFolded`, the cut) reads the same recipients. No optional recipient set is left in the file.
    - New `RoutedACPAgent.forkSourceHistory(of:forkSource:sessionId:)` makes that value with `forkRecipients(of:sessionId:)`. `forkSession` uses it.
    - New test `SessionForkTests.aMessageToTheFirstSourceIsATurnOfAForkOfAFork`: session S, fork F1, fork F2 of F1 (all real, through session/fork). A history with a session message to S, read as the source of F2, gives `beforeTurn(2)` for a cut before the next user message.
    - RED: the test did not compile before the API (missing `forkSourceHistory`). Then a mutation that gives only `[sessionId]` as recipients (the behavior of c912570) made the test fail at runtime. GREEN after the restore: SessionForkTests + SessionForkHandlerTests, 33 tests pass.
  timestamp: 2026-11-19T03:24:16.566445+00:00
position_column: doing
position_ordinal: '8180'
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

## Review Findings (2026-11-18 21:06)

> Scope: `review sha c912570~1..c912570` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:135` `completeness/invariant-propagation` — The cut maps the message to a turn with `history.turn(holding:receivedBy: [sessionId])`. The recipient set holds only the source session's own id. The doc of `turnStarts(receivedBy:)` says the set must also hold the id of each session that the source is a fork of. For a source that is itself a fork, an incoming `session_message` that names the parent id does not start a turn here. The turn index is then off by one for every cut after that message, so the fork cuts at the wrong turn. The same invariant (who counts as a recipient) must hold at every site that counts turns. Pass the full recipient set (this session plus each session in its fork chain) to `turn(holding:receivedBy:)`, as HEAD now does. Add a test with a fork of a fork where the incoming session message names the parent id, and assert the cut index counts that message as a turn.

## Review Findings (2026-11-18 21:08)

> Scope: `review sha 847d966~1..847d966` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 0 not reviewed.
