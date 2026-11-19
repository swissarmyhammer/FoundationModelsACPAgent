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
- actor: claude-code
  id: 01m7rqxgbeha4kh505szps7s04
  text: |-
    Router turn rule, detail (2026-11-18, in Router ^3hxcxee):
    - The Router counts one turn for each DELIVERED user message and each delivered DIRECTORY message (`session_message` of the session directory), in delivery order. It does not count one turn per model prompt. Tool-loop continuations and background-run mail do not add turns.
    - So the agent count must be: user messages + `session_message` entries of DIRECTORY messages (the ^qa7btpc/^ksepr6x path, id prefix `in-`). Do NOT count the `session_message` entries of the `agents` tool or of the host mail route (background-run mail). Check the entry kind before you count it, and add a test with an `agents` tool message between two user messages.
    - Batch: one Router prompt can deliver two or more waiting messages together (for example two user messages sent while the session was busy). Each message still has its own index. For a cut inside a batch the Router rounds: `.beforeTurn(n)` cuts before the whole batch that holds message n; `.afterTurn(n)` cuts at the end of the answer to that batch. The agent sends the index of the message as usual; add a test that a cut on the second message of a batch gives the same fork as a cut on the first.
    - Folded turns still count, and a cut in the folded range is still refused.
  timestamp: 2026-11-19T01:49:38.542985+00:00
- actor: claude-code
  id: 01m7rqya2dnz16cpfxc956btzn
  text: |-
    CORRECTION of the turn count (2026-11-18, final from the Router; this replaces the "do NOT count the agents tool" line of the comment before):
    - The Router counts one turn for each delivered mail whose body is `.userMessage` or `.agentMessage`, from ANY route (a user prompt, the directory, the `agents` tool, the host mail route), in delivery order. The Router journal cannot tell the routes apart (FoundationModelsAgents AgentRun.swift:794-800 builds the same mail as the directory).
    - A tool-loop continuation, a background-run result, an elicitation answer and other mail kinds add no turn.
    - Thus the agent counts each user message and EACH INCOMING `session_message` entry (directory, `agents` tool and host mail route), in delivery order.
    - Count only an incoming entry: `recipientSessionId` is this session. The projector also puts an OUTGOING view of a message that this session sent (for example a `send agent` from the root to a child) in this session's transcript; that entry was not delivered to this session, so it must not count.
    - Tests: an `agents` tool message from a child to its caller between two user messages counts as one turn; an outgoing `send agent` entry does not count; a batch cut rounds as before.
  timestamp: 2026-11-19T01:50:04.877386+00:00
- actor: claude-code
  id: 01m7rt026cbbf0xnavwz913rcb
  text: |-
    Dependency available (2026-11-18): Router ^3hxcxee is on FoundationModelsRouter origin/main 9e8de42f (with Extras 87d1da9). `RouterSessionDirectory.fork(_:)` implements all five cuts (`.lastCompletedTurn`, `.callingToolCall`, `.historyPosition`, `.afterTurn`, `.beforeTurn`).
    - Turn rule as agreed (see the comments before). `.lastCompletedTurn` never goes past the start of the running answer.
    - Errors: a cut in the folded range, a missing index, or `.afterTurn(n)` of a running turn gives `forkCutOutOfRange`. An unknown or archived source is refused. A source that does not record to disk gives `forkUnsupported`. A recorded source is restored first.
    - The fork: kind `fork`, `parentID` = source, the same profile, instructions and forked tools, name `<slug>-fork` / `-fork-2`, a first prompt (if any) as a user message after registration, no tags from the source.
    - A recorded fork is listed (kind fork) and found by id after a restart; `restoreSession(id:)` of a fork restores only the fork.
    This task starts now, in a worktree, together with the rework of ^ndqkw9s (the map changes from a history position to the turn index).
  timestamp: 2026-11-19T02:25:59.500366+00:00
- actor: claude-code
  id: 01m7rwb4bk16qtybakzvx280bd
  text: 'DECISION from the TestudoApp session (2026-11-18): follow the ACP spec. When a session/fork request OMITS `additionalDirectories`, the fork has NO additional roots (not those of the source). The app client (ACPClient `forkSession(_:cut:)`) already sends the cwd, the additional directories and the MCP servers of the source in the request. Change commit 8447ce3 in the code, the tests, README.md and ARCHITECTURE.md: an omitted `additionalDirectories` gives no roots. Check the MCP server rule against the spec the same way (an omitted list vs. an empty list) and say what the spec says. This change goes in the next round of this task, with the review findings if there are any.'
  timestamp: 2026-11-19T03:06:59.315258+00:00
- actor: claude-code
  id: 01m7rwzg3hw02mec9tkntqx7gk
  text: |-
    ### review — findings
    - evidence: `review sha 8447ce3~1..8447ce3`: 1 finding (1 confirmed, 5 refuted, 0 failed) — Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:167. No validator matched ARCHITECTURE.md and README.md.
    - next: Correct the finding in Sources/FoundationModelsACPAgent/Agent/SessionFork.swift. Then review the task again.
  timestamp: 2026-11-19T03:18:06.705093+00:00
- actor: claude-code
  id: 01m7rxnxd5nfvza7nszq3rxf2t
  text: |-
    Round 2 (finding at SessionFork.swift `openFork` + the ACP decision):
    - Finding: `openFork` now writes the history file of each fork, also an empty copy. When the directory holds no live fork for the summary id (the fork closed before the agent opened it), the handler throws an internal error and writes nothing, instead of a silent skip. `SessionMergeEngine.forkEnd(keepingToolCalls:)` now returns `nil` when no tool call is left out, and `unrecordedForkHistory` then gives an EMPTY history: a fork with no history file never shows the whole source. Discovery: the bug also hit the first open, not only a later resume: `openFork` calls `restoreColdRoot`, and with no file it took `unrecordedForkHistory`, so the fork at `beforeTurn(0)` showed both source turns at once.
    - ACP spec (FoundationModelsACP generated `ForkSessionRequest` and Schema/acp-v2.unstable.json): `additionalDirectories` — "When omitted or empty, no additional roots are activated. When non-empty, this is the complete resulting additional-root list for the forked session." `mcpServers` — "List of MCP servers to connect to for this session." with `x-deserialize-default-on-null: true` (the default is the empty list); the sibling `ResumeSessionRequest.mcpServers` says "Omitted and `[]` mean none. Agents SHOULD NOT restore servers from earlier requests." So an omitted `mcpServers` also gives no client MCP servers. The handler now uses `params.additionalDirectories ?? []` and `params.mcpServers ?? []`, as `session/new` and `session/resume` do. `forkAdditionalRoots(of:source:)` is removed.
    - Tests: `aResumeOfAForkBeforeTheFirstTurnReplaysNoTurn`, `aForkThatLeftOutNoToolCallHasNoKnownEnd`, `aForkWithNoMCPServersGetsNoServers`, `aForkWithNoDirectoriesGetsNoDirectories` (each failed first); `aForkWithMCPServersGetsTheServersOfTheRequest` now forks a source with no servers and requests one.
    - README.md and ARCHITECTURE.md state the new rules.
  timestamp: 2026-11-19T03:30:21.221686+00:00
depends_on:
- 01M7QV7B0PDJZY8YAYZNDQKW9S
position_column: doing
position_ordinal: '8280'
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

## Review Findings (2026-11-18 21:12)

> Scope: `review sha 8447ce3~1..8447ce3` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionFork.swift:167` `completeness/invariant-propagation` — `openFork` skips writing the history file when the copied history is empty (`!copied.entries.isEmpty`). A fork whose cut is `beforeTurn(0)` (a cut before the first user message) copies no entries, so no file is written. On the later restore, `unrecordedForkHistory` (SessionForkRestore.swift:71-88) treats the fork as one with no history file. It ignores the cut and rebuilds the copy from the tool-call heuristic `forkEnd(keepingToolCalls:)`. When the fork transcript has no tool calls and the source has none either, `forkEnd` returns `entries.count`, so the resumed fork shows the whole source history instead of nothing. The empty-copy case gets no equivalent treatment at the restore site that consumes the same copied history. Write the history file for every fork that has a live session, including an empty copy, so the restore never reaches the heuristic fallback for a fork that `session/fork` made. Alternatively, have `unrecordedForkHistory` return an empty history when the fork has no file and the fork was made by `session/fork`. Add a test that forks at `beforeTurn(0)` from a source with no tool calls, then resumes the fork and asserts that no source message is replayed.

## Decision (2026-11-18, TestudoApp session; see the card comment)

- [x] Follow the ACP spec: a session/fork request that OMITS `additionalDirectories` gives the fork NO additional roots (not those of the source). Change 3 above is replaced by this rule. Check `mcpServers` against the spec the same way. Change the code, the tests, README.md and ARCHITECTURE.md.
