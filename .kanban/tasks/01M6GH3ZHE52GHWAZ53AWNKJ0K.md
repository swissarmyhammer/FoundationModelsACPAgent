---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gh7beq1q0q6bg80zf5zda8
  text: 'BLOCKER (outside this board): the replay sends `subagent_update`, which does not exist in FoundationModelsACP yet (see the comment of the announce task). Also the Router tree restore may need the child ids to stay stable on disk; if it does not, write the gap here and ask the user before any Router card.'
  timestamp: 2026-11-03T11:03:03.895974+00:00
- actor: wballard
  id: 01m6gj6bzakmm694et6wc64gxr
  text: 'UPDATE of the blocker: the card now exists on the FoundationModelsACP board (id 01M6GJ664BHY454C5NFPFCSP79). The vendored unstable schema already defines subagent_update, session_message and session_message_chunk; the card adds them to the generated Swift SessionUpdate. This task starts after that card is done.'
  timestamp: 2026-11-03T11:20:00.234062+00:00
- actor: wballard
  id: 01m6gjcs4gzgj6fwttrm4fsve1
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:30.320984+00:00
- actor: wballard
  id: 01m6gkkfekwxzwbt8mcqgtn8h1
  text: |-
    DECISION (user, 2026-11-03): a child session knows its parent, and its replay ends with its OWN history, not with the response of the root. The end signal is the child state_update snapshot.
    AGENT RULE: in a replay, the agent sends the `state_update` snapshot of each child as the LAST message of that child replay. A child with no history still sends it. The agent sends the snapshots of ALL children before it sends the resume response, so no child waits for a marker that never comes.
    CLIENT RULE: a child model made during a replay starts in `.replaying`. It ends its replay on the first `state_update` for that child that arrives inside the replay (before the response). A `state_update` after the response is live and never an end signal. If the response arrives while a child is still `.replaying` (the agent sent no snapshot), end that replay as a failure and mark the child `unknown`; do not wait for ever.
    Acceptance criteria to add: the last replayed message of each child is its state_update; a child with no history sends one; all snapshots precede the response; a child made mid-replay ends on its snapshot; a live state_update after the response does not end any replay; a missing snapshot ends the child replay as a failure at the response.
  timestamp: 2026-11-03T11:44:38.355606+00:00
- actor: wballard
  id: 01m6gkyspw08vz98223qkc6prt
  text: |-
    DECISION (user, 2026-11-03), SUPERSEDES the earlier comment "a child session knows its parent, and its replay ends with its OWN history" (the per-child end on a state_update snapshot before the response). That text misread the subagents RFD. FOLLOW ACP (RFD "Subagent Sessions", section replay and resume):
    - All history of the tree (associations and child history) is sent BEFORE the resume response ("All history selected for this replay MUST be sent before the response"). The response completes the best-effort child replay. A child replay ends at the response. There is no per-child end marker in ACP.
    - When replay is requested, the successful response is the freshness boundary for child work state and mutation-capability snapshots. Snapshots sent before the response are historical: they MUST NOT authorize client mutations and MUST NOT confirm current activity. Current snapshots are sent AFTER the response. Without a replay, announcements and snapshots may come before or after the response.
    - The ancestor chain is announced parent before child, before any use of a child in live traffic. Replay MUST NOT reissue permission, elicitation or other agent-to-client requests.
    AGENT: replay (associations, child history, no child state_update as a current fact) -> parent current state_update snapshot (with the `background` list) and session info -> response -> current `subagent_update` snapshots of every child (state and capabilities) -> only then any re-drive (a snapshot must precede a running update of the same child so a delayed copy cannot overwrite a newer state). A cold-restored child snapshot is `idle`. Do not echo a synthetic user_message for a re-drive mail (agent-started foreground work needs none).
    CLIENT: on resume the client invalidates cached child work state and capabilities. Child models made during the replay are `.replaying` and end their replay at the RESPONSE of the root request. After the response a child is UNCONFIRMED (shown as unknown, effective capabilities empty) until its first current snapshot; child controls (cancel) stay disabled until then, and until the resume has succeeded. Everything inside the replay phase is history: no notification, sound, attention mark or auto action. Add `SessionModel.isWorkStateConfirmed` (or an equivalent) as an observable.
    Acceptance criteria to add: no child current snapshot before the response in a replay; every child gets a snapshot after the response; a child is unconfirmed and not cancellable between the response and its snapshot; the re-drive start follows the snapshots; a replay with no replayFrom still announces the children and sends current snapshots; no needsAttention or notification is raised by replayed content.
  timestamp: 2026-11-03T11:50:49.308449+00:00
- actor: wballard
  id: 01m6h6kdbpey8ckgzpz99webmx
  text: |-
    SPEC REVIEW (independent, ACP session, 2026-11-03) of the committed code; items for THIS task:
    1. SessionHistory.replayUpdates(from:) returns transcriptUpdates + stateUpdates. stateUpdates starts with the subagent_update announcements, so a session_message that names a child would be replayed BEFORE the child is announced. Rule: in the replay every announcement comes before any update, request or message that carries or names its child id, parent before child.
    2. The replay keeps every non-state update of stateUpdates (session_info_update, usage, config options) before the current state_update, and the sync sends session_info_update again after it. Fix: the replay holds the transcript and the child announcements only. Historical session_info, usage, config options and commands are optional in a replay; the CURRENT ones follow the current state_update and the response carries the config options and commands.
    3. The retained history is written to session-history.json with the folded child snapshots (state running, capabilities.cancel). After a process restart the replay sends them before the response, but the children are not restored yet, so there is no run behind them. Fix: a replayed announcement carries NO capabilities, and its state is only what was true at the end of the history (the client treats a child state before the response as history). Never replay capabilities.
    4. A child entry has its own SessionMergeEngine, but the resume replays only the root engine: the child messages and tool calls are never replayed. Replay each child history under its own id (this task), parent before child.
    The ACP validator (SubagentWireTraceValidator, wire 364a19a) checks these rules: run the real resume output through it in a test.
  timestamp: 2026-11-03T17:16:39.158625+00:00
depends_on:
- 01M6GJPPXWKQJ9E6SK5WD0CWZ7
- 01M6GH30709S58BK3AQ1VMBAM7
- 01M6GM0N9BFK37GGBWPAG9VE1X
position_column: todo
position_ordinal: '8680'
title: 'Replay the nested tree on session/resume with replayFrom start: announcements and child history before the response'
---
## What
v2 has no `session/load`. `session/resume` with `replayFrom: {type: "start"}` replays the history. Add the nested tree to that replay, following the ACP subagents RFD (see the rule list below). The sessions are restored and registered by the cold resume task (a dependency); this task sends the history of the tree on the wire.

Rules (ACP "Subagent Sessions" RFD):
- The agent announces the full ancestor chain, parent before child, with `subagent_update`, before any child traffic. A missing intermediate ancestor is still announced (identity, not a live runtime). Never guess a parent; never invent an id.
- Replayed child updates keep their original session ids, parentage and per-session order. All history selected for the replay is sent BEFORE the response. The response completes the best-effort child replay.
- Replay must not reissue permission, elicitation or other agent-to-client requests.
- Current child state and capability snapshots are NOT part of the replay: they come after the response (child sync task).
- The child `session_message` history is replayed under the right transcript when the `session_message` wire type exists.

Where: `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (`replayHistory`) and `SessionHistory.swift` (`replayUpdates`). Each child has its own retained history (`retainedHistory` of its session entry); replay each under its own id.

## Acceptance Criteria
- [ ] A resume with `replayFrom: start` of a root with a nested chain of sessions (root, child, grandchild) sends: announcements parent first, then the history of each session under its own id, all before the response.
- [ ] No child event comes before its `subagent_update`.
- [ ] No permission or elicitation request is sent during the replay.
- [ ] No child current-state snapshot is sent before the response.
- [ ] A resume with no `replayFrom` sends no history.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift`: record a nested session with the stub model, resume, check the order of the wire messages.
- [ ] Run `swift test --filter SubagentSessionsReplayTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents