---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qy5sp97gys03jk5s32816b
  text: 'BLOCKER found in ^ndqkw9s (2026-11-18, branch worktree-agent-a61744b3912f01012 @ 847d966). The map of ^ndqkw9s counts entries of the agent''s ACP retained history (`SessionMergeEngine.entries`). The Router reads `SessionForkCut.historyPosition(n)` as its own journal ordinal (entry-kind events: instructions, prompt, toolCalls, toolOutput, response, reasoning). The two counts differ, so a direct use forks the wrong history. The public Router API cannot map them (`historyOrdinal`, `mailRecords`, `MailRecordSegment` are internal), and the agent message ids are random ULIDs that the Router journal does not record. ^ndqkw9s gives `SessionForkPoint.retainedHistoryPosition(n)`, not a `SessionForkCut`. I asked the Router session for (a) an ordinal API by turn or prompt mail id, (b) a cut in turn units, or (c) a recorded ACP message id. This task waits for that answer. Also: Extras 92660bf has no `SessionForkCut`; update Extras.'
  timestamp: 2026-11-18T18:19:47.273784+00:00
- actor: claude-code
  id: 01m7qy6dmxb4rc2539ndw2b719
  text: 'Cut design (2026-11-18, from the TestudoApp session): the Router gets a cut in TURN units. One turn = one user message and everything until the next user message. "After turn n" for a cut after an agent message; "before turn n" for a cut before a user message. The agent maps the ACP message id to its turn index from its history; the Router maps the turn index to its journal. The Router sends the final API. Thus change the map of ^ndqkw9s (`SessionForkPoint.retainedHistoryPosition(n)`) to a turn index. A cut after an agent message in the middle of a turn rounds to the end of that turn.'
  timestamp: 2026-11-18T18:20:07.709054+00:00
- actor: claude-code
  id: 01m7qy77trc2g0yzedjf319m7r
  text: |-
    Router cut rule (2026-11-18, Router task ^3hxcxee; Extras adds `SessionForkCut.afterTurn(Int)` and `.beforeTurn(Int)`):
    - A turn is one `prompt` entry and all entries up to the next `prompt` entry. A `prompt` entry is a user message, OR a delivered mail that starts an answer (a message from another session, a delivered inbox message). So count each user message and each delivered `session_message` that starts a turn.
    - The index is 0-based: turn 0 is the first prompt after the instructions.
    - Fork from Here on an agent message: `.afterTurn(n)` of the turn that holds the message (a cut inside a turn rounds to the end of the turn). On a user message: `.beforeTurn(n)` of its own turn.
    - An index that does not exist, or `.afterTurn(n)` of a turn that still runs, gives `forkCutOutOfRange`; map it to invalid params.
    - OPEN: compaction. The retained ACP history keeps every turn (SessionHistory.swift:14-17), but the Router counted turns in the compacted history. I asked the Router to count all prompt entries ever recorded, and to define a cut inside the folded range. Wait for the final rule with the sha of ^3hxcxee.
  timestamp: 2026-11-18T18:20:34.520134+00:00
- actor: claude-code
  id: 01m7qy7nnmr8f4yfrhyv2vvdb7
  text: |-
    FINAL cut rule, agreed with the Router (2026-11-18):
    - The turn index counts EVERY prompt entry ever recorded for the source, also the turns that a compaction folded. It is 0-based from the first prompt. Count each user message and each delivered `session_message` that starts a turn, over the whole retained ACP history.
    - Fork from Here on an agent message: `.afterTurn(n)` of the turn that holds it. On a user message: `.beforeTurn(n)` of its own turn. No cut: the last completed turn.
    - A cut after the last compaction: the fork gets the compaction summary plus the turns after it, up to the cut.
    - A cut inside the folded range: the Router REFUSES with `forkCutOutOfRange`, because the summary also covers turns after the cut. Show a clear text, for example "This part of the session was compacted. Fork from a later turn." The agent can tell this case from its own retained history (the compaction entries), so give this text only in this case.
    - An index that does not exist, or `.afterTurn(n)` of a turn that still runs: also `forkCutOutOfRange`; give a different clear text. Map both to invalid params.
    - Change the map of ^ndqkw9s from `retainedHistoryPosition(n)` to the turn index.
    Wait for the sha of Router ^3hxcxee and the Extras sha of `SessionForkCut.afterTurn/beforeTurn`.
  timestamp: 2026-11-18T18:20:48.692002+00:00
- actor: claude-code
  id: 01m7qybeyk7xsavqpqnt5p91nr
  text: 'Dependency available (2026-11-18): Extras origin/main 87d1da9 (code commit 96fea25) has `SessionForkCut.afterTurn(Int)` and `.beforeTurn(Int)`. The other cases are `.lastCompletedTurn`, `.callingToolCall` and `.historyPosition(Int)`. The operation is `SessionDirectory.fork(_ request: SessionForkRequest)`. `.beforeTurn(n)` cuts just before the prompt of turn n; `.afterTurn(n)` cuts at the end of turn n. An index that does not exist, or `.afterTurn(n)` of a turn that still runs, throws `SessionDirectoryError.forkCutOutOfRange`. If this package matches `SessionForkCut` with a switch, add a `default:` or match with `if case`, so a later case does not break the build. Still waiting for Router ^3hxcxee.'
  timestamp: 2026-11-18T18:22:52.883261+00:00
- actor: claude-code
  id: 01m7rg6hfnx6z8t9kgg0vy8rg2
  text: 'Dependency available (2026-11-18): `fork session` / `forkSession` is on FoundationModelsMultitool origin/main, commit bdbebea3 (head 568fa2a5). With no `id`, the tool forks the CALLER at `SessionForkCut.callingToolCall`. Thus, when the Router fork lands (^3hxcxee), make sure that a `fork session` call from a session of this agent reaches `RouterSessionDirectory.fork(_:)` with `.callingToolCall`, and that the Router can find the running tool call of the caller (the cut is the history up to the call, not the call). With no directory fork support, the tool gives FORK_UNSUPPORTED. Add a test: an agent of this server calls `fork session` with no `id`, and the fork has the history up to that call.'
  timestamp: 2026-11-18T23:34:46.005288+00:00
depends_on:
- 01M7QV7B0PDJZY8YAYZNDQKW9S
position_column: todo
position_ordinal: 8f80
title: 'D205: session/fork makes the fork through the Router, with the grants, MCP servers and directories of the source'
---
Decision D205 in `TestudoApp/features/decisions.md` (commit 483664d). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/fork/acpa-brief.md`, changes 3 and 4. Overview: `overview.md` in the same folder.

## Dependencies

- ^ndqkw9s (the capability, the handler and the message id map).
- FoundationModelsRouter on `main` (`router-brief.md`): `RouterSessionDirectory.fork(_:)` (live fork with a cut point, record, recording node, hooks, default name `<slug>-fork`). FoundationModelsExtras on `main`: `SessionDirectory.fork(_:)`, `SessionForkRequest`, `SessionForkCut`. Not on this board: do not start until the Router sha comes.

## Change

1. The `sessionFork` handler calls `RouterSessionDirectory.fork(_:)` with the source id, the cut of ^ndqkw9s, no first prompt, and the connection as `requestedByClient`.
2. The fork gets the permission grants of the source for this session ("allow for this session" grants).
3. The fork gets the MCP servers of the request, else those of the source; and the additional directories of the request, else those of the source.
4. Answer `ForkSessionResponse` with the new `sessionId`, the `configOptions` and the `availableCommands` of the fork.
5. A `session/resume` of the fork replays the copied history and then the own history of the fork, so that the client shows the copied turns.
6. The `sessions` tool and endpoint: they run over `context.sessionDirectory` (the Router directory, `Tools/ToolCatalog.swift:564-569`). Make sure that `fork session` / `forkSession` of FoundationModelsMultitool reaches `RouterSessionDirectory.fork(_:)` here, with a fork cut at the tool call. Add wiring only if the tool needs it.
7. The `sessions` skill does not change here (Multitool owns it).
8. When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a).

## Tests

- `session/fork` with no cut on a session with two completed turns and one running turn: the fork has the two turns; the running turn continues in the source.
- `session/fork` with `after` the agent message of turn 1: the fork has turn 1 only.
- `session/fork` with `before` the user message of turn 2: the fork has turn 1 only.
- `session/fork` with an unknown message id: invalid params, no fork.
- A tool that the source allowed for the session runs in the fork with no new permission request.
- `session/resume` of the fork replays the copied turns.
- The `sessions` tool `fork session` makes a fork through the Router directory. #d205 #fork