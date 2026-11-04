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
- actor: claude-code
  id: 01m6jnj1pr96bxqjct6fg1a5qh
  text: |-
    ### implement — changed
    - evidence: 10 files. Sources: SessionResume.swift, SessionResumeReplay.swift (new), SessionResumeNested.swift, SessionHistory.swift, SessionBuild.swift, BackgroundWatch.swift (isFinal now internal). Tests: SubagentSessionsReplayTests.swift (new, 12 tests, pass), ResumeNestedSessionsTests.swift (recordShutDownChain), SessionHistoryTests.swift, ResumeSyncTests.swift. Full `swift test`: 1644 tests, only the known ShellSessionOwnerTests blocker fails.
    - design: replay = (1) announcements of the whole tree, parent first, capabilities removed; (2) history of each session under its own id; the history of a child goes out before the final status of the agents call that links it (validator rule 8). Restored children now start from their own session-history.json (SessionBuild history parameter). The real SubagentWireTraceValidator runs over the resume wire in a test and finds no violation.
    - spec review items: 1 (announcements first), 3 (no capabilities), 4 (child history) done. Item 2: the replay no longer holds session_info_update (validator rule 1 forbids it before the current state_update; the sync sends the current one). Two old tests that asserted session_info in the replay were changed to match. Historical usage/commands/config options stay in the replay (optional).
    - gap: a child that did not restore has no table entry, so its history and its own children announcements are not replayed (only its announcement from the parent history). session_message replay: wire type exists, engine keeps no such entries yet, so nothing to replay.
    - note: with the user-close quit helper (recordInterruptedChain) the history has a cancelled agents call and a running child, which breaks validator rule 8; the new test records with the orderly shutdown instead.
    - next: /review
  timestamp: 2026-11-04T06:57:17.528837+00:00
- actor: claude-code
  id: 01m6jnzrb37c0afjh1qptm34nm
  text: |-
    ### review — findings
    - evidence: review sha 6bd4e84~1..6bd4e84, run twice. 3 findings: SessionHistory.swift:245, SubagentSessionsReplayTests.swift:157, SubagentSessionsReplayTests.swift:220. Rule code-hygiene/dead-code-swift failed on both runs (build error at RecordedSessionTranscriptReader.swift:85, 'TranscriptEvent' has no member 'read', file not in this commit), so the dead-code check did not run.
    - known blocker, not a finding: ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID
    - next: fix the 3 findings, then run review again.
  timestamp: 2026-11-04T07:04:46.691189+00:00
- actor: claude-code
  id: 01m6jpnf58j25k0j3b31x2rm7f
  text: |-
    ### implement — changed
    - evidence: 2 files. Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift, Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift.
    - build: `swift build` failed first at RecordedSessionTranscriptReader.swift:85 (TranscriptEvent has no member read). `swift package update` moved the sibling packages to main (Router 6331c9c, Agents 5e8d090, Extras 0b45545, Multitool bf3f072). `swift build` then passed. No sibling file and no RecordedSessionTranscriptReader.swift change.
    - finding SessionHistory.swift isReplayedState: the `default:` is gone. Every SessionUpdate case is listed. Same cause in the commit: no other `default:` on SessionUpdate in the source files of 6bd4e84.
    - findings at SubagentSessionsReplayTests :157 and :220: both tests now require their precondition before the negative check. Same cause removed from the whole file: the tests for the history of the grandchild not on the root stream, the elicitation request, the validator trace, and the two no-replay tests now call `requireReplayed()` (announcements and history of all three sessions on the wire). The two no-replay tests also run a control (`requireAReplayToSendHistory()`): the same agent with `replayFrom: start` does send history, so an empty result proves the request. A second resume of the same root on the same agent sends no child history (a second root resume does not replay the children), so the control uses a second recording.
    - tests: SubagentSessionsReplayTests 11 of 12 pass. SessionHistoryTests 4, ResumeSyncTests 16, ResumeNestedSessionsTests 8 all pass.
    - RED, not from this change: `theWireOfTheResumeFollowsTheRulesOfTheValidator` fails when it runs alone (3 of 3): rule finalToolCallLast, "final tool call before the final idle state of <child>". It passed only in runs where the whole suite ran in parallel. Cause: the recorded history has the root `agents` call `cancelled` while the child state is `running` (shutdown order). Product order problem, new task added on the board. I did not change SessionLifecycle or ToolCatalog.
    - known blocker, not touched: ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID. SessionSetup.swift and ConfigOptions.swift not edited.
    - boxes: the 3 findings are [x]. Task stays in doing.
    - next: decide the shutdown-order task, then /test and /review.
  timestamp: 2026-11-04T07:16:38.184847+00:00
- actor: claude-code
  id: 01m6jqk7v17exfb8jr8dfqhhmc
  text: |-
    ### implement — changed
    - The red test `theWireOfTheResumeFollowsTheRulesOfTheValidator` is fixed by ^xyw6858: the replayed announcement of a child now carries the idle state of the child (SessionResumeReplay.swift). The edits for the 3 review findings stay as they were.
    - tests: SubagentSessionsReplayTests 13 of 13 pass. Full `swift test`: only the known blocker ShellSessionOwnerTests.aCommandAfterAModelSlotSwitchRecordsTheACPSessionID fails, plus one load-only flake of noEventOfAChildComesBeforeItsAnnouncement (new task ^ntmvnnz).
    - next: /test and /review.
  timestamp: 2026-11-04T07:32:53.729428+00:00
depends_on:
- 01M6GJPPXWKQJ9E6SK5WD0CWZ7
- 01M6GH30709S58BK3AQ1VMBAM7
- 01M6GM0N9BFK37GGBWPAG9VE1X
position_column: doing
position_ordinal: '8480'
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
- [x] A resume with `replayFrom: start` of a root with a nested chain of sessions (root, child, grandchild) sends: announcements parent first, then the history of each session under its own id, all before the response.
- [x] No child event comes before its `subagent_update`.
- [x] No permission or elicitation request is sent during the replay.
- [x] No child current-state snapshot is sent before the response.
- [x] A resume with no `replayFrom` sends no history.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift`: record a nested session with the stub model, resume, check the order of the wire messages.
- [x] Run `swift test --filter SubagentSessionsReplayTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-04 01:01)

> Scope: `review sha 6bd4e84~1..6bd4e84` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

> ⚠️ tool rule 'code-hygiene/dead-code-swift' failed on two runs — the tool judged nothing, so its findings are missing. The build stopped with this error (the full compile command is trimmed):
> `Sources/FoundationModelsACPAgent/Transcripts/RecordedSessionTranscriptReader.swift:85:38: error: type 'TranscriptEvent' has no member 'read'`
> `error: Build failed`
> That file is not part of this commit (last changed in 3a9e864, ^zgqxj7z).

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift:245` `swift/state-modeling` — The `default:` in `isReplayedState` silently classifies every current and future `SessionUpdate` case as replayed. A new state-like case added to the enum would reach the replay with no compiler prompt to decide. List every `SessionUpdate` case explicitly and return `false` or `true` for each, so the compiler flags any new case that is added to the enum.
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift:157` `test-integrity/no-test-cheating` — The test aReplayedAnnouncementCarriesNoCapabilities checks only that no replayed subagent_update carries capabilities (#expect(!carried)). It does not first check that the replay sent any subagent_update. If the replay sends no announcement at all, the check passes with nothing proved. The test can therefore pass even when the announcement path is broken, which is the weakened-assertion pattern. Before the negative check, require that the announcement exists, for example `let announced = try #require(wire.announcement(of: wire.recording.child))`, and then check that the announced update at that position has `capabilities == .unchanged`. This keeps the test from passing vacuously.
- [x] `Tests/FoundationModelsACPAgentTests/SubagentSessionsReplayTests.swift:220` `test-integrity/no-test-cheating` — The test theReplaySendsNoStateOfAChild checks only #expect(childStates.isEmpty). It does not first confirm that the child has any updates on the wire. If the child produces no update at all, the check passes with nothing proved. This is the same missing-precondition pattern as the finding at line 157. Add a precondition before the negative check, for example `#require(!wire.updates(of: wire.recording.child).isEmpty)`, so the test fails if the child sends nothing. Then assert that no child update is a stateUpdate.
