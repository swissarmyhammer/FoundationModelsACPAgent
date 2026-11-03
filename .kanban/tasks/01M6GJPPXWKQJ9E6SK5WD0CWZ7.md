---
comments:
- actor: wballard
  id: 01m6gjyqz90k8hmp6205zhqnwz
  text: |-
    REQUIREMENT (user, 2026-11-03): an agent used as a tool is fundamentally a session that returns its result to the calling session. A resume must work for sessions that are IN PROCESS, together with their in-process sub-agent sessions, and not only for sessions on disk. Two cases, one rule:
    1. COLD resume (nothing live in this process): restore the root and the recorded nested sessions from disk (the description of this task).
    2. HOT resume (the session, and maybe running sub-agent runs, are live in this process): the new connection takes the session and its whole tree, gets the replay of the history of every session in the tree, and the live work CONTINUES: running prompts, running sub-agent runs, and pending requests are not cancelled.
    FINDING (read in the code, not run): the hot case does not exist today. `resumeSession` in `Agent/SessionResume.swift` (near line 195) tears a live entry down first: "A live entry gets the full teardown of `session/close` first: its open prompts end with `idle(cancelled)`, its Router session closes and its projector stops" (`tearDownSession`), then it restores from disk. The session lifecycle also stops the `AgentRunner` before it closes the root session (`AgentsMount.runner` doc in `Tools/AgentsComposition.swift`), so the running sub-agent runs are stopped too. A hot resume therefore kills the live work. Change: when the entry is live and not closed, do not tear it down; move the owner (`takeSession`), keep the projectors, and replay the retained history of the root and of each child (the `retainedHistory` of each `ActiveSession`), under their own ids, parent first. Pending requests of the tree go to the new owner (the existing D120 rule: the old owner gets none). Decide with the user if a hot resume of a session with an open prompt keeps the prompt open (my reading of the requirement: yes).
    Add acceptance criteria and tests: a hot resume of a root with a running depth 2 sub-agent run keeps the run going and the run ends normally; the replay under the new connection holds the root and the child history; the old connection gets no more updates; a pending child request is asked once, on the new owner.
  timestamp: 2026-11-03T11:33:18.953727+00:00
- actor: wballard
  id: 01m6gjz3d0jrcp24v3sbmdh7ak
  text: 'DECISION (user, 2026-11-03): a sub-agent session that is restored from disk (cold resume) comes back IDLE. It is not started again and it does not continue its old work. The child announces `state: idle`; it keeps its id and can get new work from its parent later (the RFD: a child is reusable, idle does not end it). A sub-agent run that is still running in this process (hot resume) is not restored, because it was never stopped: it keeps running. Add acceptance criteria: after a cold resume each restored child has workState idle and its history is replayed; after a hot resume a running child stays running.'
  timestamp: 2026-11-03T11:33:30.656388+00:00
- actor: wballard
  id: 01m6gkkeq3e9pm3vgy8x286h4k
  text: |-
    DECISION (user, 2026-11-03): a child session knows its parent, and its replay ends with its OWN history, not with the response of the root. The end signal is the child state_update snapshot.
    AGENT RULE: in a replay, the agent sends the `state_update` snapshot of each child as the LAST message of that child replay. A child with no history still sends it. The agent sends the snapshots of ALL children before it sends the resume response, so no child waits for a marker that never comes.
    CLIENT RULE: a child model made during a replay starts in `.replaying`. It ends its replay on the first `state_update` for that child that arrives inside the replay (before the response). A `state_update` after the response is live and never an end signal. If the response arrives while a child is still `.replaying` (the agent sent no snapshot), end that replay as a failure and mark the child `unknown`; do not wait for ever.
    Acceptance criteria to add: the last replayed message of each child is its state_update; a child with no history sends one; all snapshots precede the response; a child made mid-replay ends on its snapshot; a live state_update after the response does not end any replay; a missing snapshot ends the child replay as a failure at the response.
  timestamp: 2026-11-03T11:44:37.603295+00:00
- actor: wballard
  id: 01m6gkq7f7c5faekdecfv8narr
  text: |-
    DECISION (user, 2026-11-03), gap 4: a child session that fails to restore is announced, not hidden. The agent sends `subagent_update` for it with `state: unknown` and a short reason in `_meta` (for example missing tool, model mismatch, record unreadable). The RFD meaning of `unknown` is lost observability while ACP stays connected; it is nonterminal and the client must not show stale activity as live. The root still resumes.
    THIS REPLACES the earlier text of the cold resume task that says a failed child is kept out of the tree and is not in `children`: a failed child IS in the tree, as unknown.
    AGENT: a failed child has no live Router session, so there is no projector, no history, and no `capabilities` (no cancel). Announce it with its stable id, its parent (from `agentSpawn.parentSessionId`, which is known, so no guess), its title, `state: unknown`, `capabilities: null`, and the reason in `_meta`. Its own replay ends with that announcement (no history to send). Its descendants cannot be restored either: announce them as unknown too, or not at all; decide and write it in a task comment.
    CLIENT: the child model has `workState` unknown and an observable `restoreFailure` (a short reason string, nil when fine). A view shows it as lost, with the reason, and offers no prompt or cancel. It counts in `children`, `descendants` and `ancestors`. `needsAttention` is false for it unless the user must act (decide in the client card).
    Acceptance criteria to add: a recorded child with a missing tool resumes the root, and the client sees the child as unknown with the reason; no cancel capability; the child keeps the same id on a second resume; descendants of a failed child follow the written rule.
  timestamp: 2026-11-03T11:46:41.255650+00:00
- actor: wballard
  id: 01m6gkyrx48seb1x8jb8xsv1es
  text: |-
    DECISION (user, 2026-11-03), SUPERSEDES the earlier comment "a child session knows its parent, and its replay ends with its OWN history" (the per-child end on a state_update snapshot before the response). That text misread the subagents RFD. FOLLOW ACP (RFD "Subagent Sessions", section replay and resume):
    - All history of the tree (associations and child history) is sent BEFORE the resume response ("All history selected for this replay MUST be sent before the response"). The response completes the best-effort child replay. A child replay ends at the response. There is no per-child end marker in ACP.
    - When replay is requested, the successful response is the freshness boundary for child work state and mutation-capability snapshots. Snapshots sent before the response are historical: they MUST NOT authorize client mutations and MUST NOT confirm current activity. Current snapshots are sent AFTER the response. Without a replay, announcements and snapshots may come before or after the response.
    - The ancestor chain is announced parent before child, before any use of a child in live traffic. Replay MUST NOT reissue permission, elicitation or other agent-to-client requests.
    AGENT: replay (associations, child history, no child state_update as a current fact) -> parent current state_update snapshot (with the `background` list) and session info -> response -> current `subagent_update` snapshots of every child (state and capabilities) -> only then any re-drive (a snapshot must precede a running update of the same child so a delayed copy cannot overwrite a newer state). A cold-restored child snapshot is `idle`. Do not echo a synthetic user_message for a re-drive mail (agent-started foreground work needs none).
    CLIENT: on resume the client invalidates cached child work state and capabilities. Child models made during the replay are `.replaying` and end their replay at the RESPONSE of the root request. After the response a child is UNCONFIRMED (shown as unknown, effective capabilities empty) until its first current snapshot; child controls (cancel) stay disabled until then, and until the resume has succeeded. Everything inside the replay phase is history: no notification, sound, attention mark or auto action. Add `SessionModel.isWorkStateConfirmed` (or an equivalent) as an observable.
    Acceptance criteria to add: no child current snapshot before the response in a replay; every child gets a snapshot after the response; a child is unconfirmed and not cancellable between the response and its snapshot; the re-drive start follows the snapshots; a replay with no replayFrom still announces the children and sends current snapshots; no needsAttention or notification is raised by replayed content.
  timestamp: 2026-11-03T11:50:48.484722+00:00
- actor: wballard
  id: 01m6gnhrvq4nb7kpk8arw6gtq6
  text: 'UPDATE: the FoundationModelsAgents restore card now exists: id 01M6GNHC0MV9FBT33Z9DTT5TVA on the Agents board (AgentRunner restores a recorded child run from disk with tools and instructions from the current config, as an idle run). This task is blocked by it. The text "no card yet" in the description is out of date.'
  timestamp: 2026-11-03T12:18:39.607900+00:00
- actor: wballard
  id: 01m6gns76sc49f46cegds5gbb2
  text: |-
    DECISION (user, 2026-11-03): if an agent session is DONE, there is nothing to restore. When an agent finishes, its session is ended and removed. Agents runs stay ONE-SHOT (no idle state in AgentRunState).
    EFFECT ON THIS PLAN:
    - A resume restores ONLY the sub-agents that were still working (interrupted) when the process stopped. Finished children are not restored and are not announced as part of the restored tree.
    - The set to restore is the set of orphan runs of the parent (a run with a non-terminal journal event and no completed). This is the same set that the Router claim card (01M6GK8K45DRDT6B4SHB9V60ED) lets a host claim. The two tasks are one flow: claim, restore, continue, complete the original call.
    - This replaces: "restore every recorded sub-agent session, found through agentSpawn.parentSessionId, all idle" (cold resume), and "a restored child comes back idle and can get new work later". A restored interrupted child is announced idle in the first snapshot after the response, then goes running when it is continued (re-drive), after the response. It ends once; then it is removed like any finished child.
    - The Agents restore API (card 01M6GNHC0MV9FBT33Z9DTT5TVA on the Agents board, rewritten) restores and continues in one call.
    - To verify first: how the host finds the child session of an orphan run after a crash (orphan RunKey -> SDK tool call id in the journal -> recorded child with agentSpawn.parentToolCallId). The runner map from completion token to run is in memory and is lost in a crash.
    - Open (the user decides): how the live ACP tree tells the client that a finished child is gone. ACP has no removal message; a child stays an idle association.
  timestamp: 2026-11-03T12:22:43.673798+00:00
- actor: wballard
  id: 01m6gptcnpkmsgvbazamff97f8
  text: |-
    DECISION (user, 2026-11-03), from the review by the Agents session: a finished agent session is NOT removed from disk by the Router (close() unregisters it but keeps the recording; the record has no ended field). So "a finished child is not restored" needs a marker. The user chose: MARK THE RECORD AS ENDED (the recording stays for history). Router card: 01M6GPT1DM4KZNTT31NMQ0962J "Mark a session record as ended, so a host can tell a finished sub-agent run from an interrupted one". The host (FoundationModelsAgents) sets the marker when a run reaches a terminal state.
    EFFECT: this task and the re-drive task are BLOCKED by that card for the rule "finished children are not restored". Until it is done, the only way to find interrupted children is the orphan scan of the parent, which misses a child that crashed before its first journal event. Other Router needs of the restore (not decided, no card yet): a public lookup of recorded children by agentSpawn.parentToolCallId and a public orphan scan that does not need the restore of the parent; restore parameters for parentCall, the compaction settings and mailOnlyAnswerLimit (these come from the recording today, against the user rule that config comes from the current config).
    The chain to find the child of an orphan run is shorter than first written: orphan RunKey.correlationID (the completion token) equals the child agentSpawn.parentToolCallId, with parentSessionId equal to the parent. The SDK tool call id is not part of it.
  timestamp: 2026-11-03T12:40:50.614465+00:00
- actor: wballard
  id: 01m6h07ns2w7n8ahzdpgtjqe58
  text: |-
    DECISION (coordinator, 2026-11-03), failed children on resume:
    1. A child that FAILS to restore is announced with a subagent_update: state unknown, no capabilities, and `_meta.sah.restoreFailure = { reason }` (typed wire payload SAH.RestoreFailure, being added by the ACP session; send the full `sah` object, since _meta patches by top-level key).
    2. Each DESCENDANT of a failed child is announced the same way (unknown, parent before child), with the reason "an ancestor was not restored". They cannot be restored because their caller is not restored.
    3. The client clears restoreFailure when a later current subagent_update with a state arrives. A silent agent (no current snapshot after the response) is NOT a failure: the child stays unconfirmed (unknown, controls disabled). The client has no timer.
    4. The original call of the failed child ends as lost (the Router claim API closes an open claim as lost).
    Add acceptance criteria and a test for items 1 and 2 (a failed child and its descendants announced unknown with the reason, the root still resumes).
  timestamp: 2026-11-03T15:25:23.106541+00:00
- actor: wballard
  id: 01m6hccr0sn2wr8135zk7b3ak6
  text: |-
    MULTITOOL AUDIT (read-only, 2026-11-03) items for the restore in this task:
    (a) Shell records are memory only: after a restore, handles of earlier shell commands are gone (getLines(oldToken) throws unknownCommand). The continue message to a restored run must say: earlier shell command handles and background shell output are no longer available; start the command again if you still need it.
    (b) The snapshot verbs need the session key reopened after a restore: SnapshotsContext reads HookSession.current and the default key is the session id; if the host does not reopen it the verb returns unavailable. The host must reopen the key (SnapshotSessionKeys.record for the restored session and for each restored child, with the hook lineage of its root) BEFORE the first submission of each restored session. Add a test.
    (c) The Registry (MCP servers, shell store, file context) is rebuilt in the new process before makeSessionTools: the agent package builds its registry at startup, so restored runs are built from the CURRENT registry; a Multitool accessor for the current registry is being added on the Multitool board (card pending): use it when it lands.
    (d) A restored run must not reuse the completion tokens of Multitool inner runs (status and cancel of an old token answer "no run under that handle"). The restored agents call keeps ITS OWN old token (that is the claim); inner shell and runCode tokens are not restored.
    (e) A crash can leave shell child processes and stdio MCP servers running; a Multitool card reaps them at store init.
  timestamp: 2026-11-03T18:57:52.153831+00:00
- actor: wballard
  id: 01m6hg2mtayfccyb85nd4rykbm
  text: |-
    HOOKS REPORT ITEM (independent, 2026-11-03): FoundationModelsRouter Session/SessionHooks.swift near lines 172 to 175: when the parent is not open, the hook key of a sub-agent is the id of its parent. The ACP roots use the PROJECT key (Agent/AgentHooks.swift near 71 to 83, SessionResume.swift near 209). A child that is restored BEFORE its root, or whose root key is not passed, gets a different key, so a separate snapshot timeline for one work tree.
    RULES FOR THIS TASK: (1) restore the ROOT session first, with its project hook key (hookSessionKey), and only then call the Agents restoreInterrupted facade, which restores caller-first, so every restored child finds its root open and gets the root key; (2) check how the host passes hookSessionKey (SessionSetup.swift near 1178, SessionResume.swift near 399) for restored children and fix it if a child can be restored without it; (3) write a test: after a cold resume, the hook key of the root, of a restored child and of a restored grandchild is the SAME project key, and the snapshot timeline is one; also the same test for the SnapshotSessionKeys record of each restored session; (4) SessionEnd at an orderly quit is sent for runs that are suspended (the Hooks session adds a reason: completed, suspended, released; the Router sets it): a snapshot or cleanup hook of this package must not treat a suspended SessionEnd as done; check AgentHooks.swift and the snapshot hooks for work on SessionEnd and test that a quit does not delete the timeline.
  timestamp: 2026-11-03T20:02:15.498730+00:00
- actor: claude-code
  id: 01m6hj6wv8kfpz8ms8kp1sja4j
  text: 'MULTITOOL PUSHED (main 5a900fdb): MultiTool.currentRegistry is public (980dd817). Use it to build restored runs from the CURRENT registry. Also pass crashRecordDirectory to StdioServerProcess, else the reaping of stdio servers after a crash stays off (5a900fdb). The shell owner now comes from the ToolContext session id (746da544). Run swift package update before this task.'
  timestamp: 2026-11-03T20:39:31.944615+00:00
depends_on:
- 01M6GH2K0VV6RWV5R6SN3HB9SV
position_column: todo
position_ordinal: '8980'
title: 'Cold resume: restore the recorded nested sub-agent sessions with their parent, idle, with tools from the CURRENT config'
---
## What
`session/resume` of a session that is NOT live in this process must restore the whole tree of recorded nested sessions, not only the root. (User, 2026-11-03: Claude Code does not resume sub-agent sessions, and that is not acceptable here.) This task restores and registers the sessions. It sends nothing new on the wire: the replay task and the child sync task do that.

Today (read in the code, not run): `resumeSession` -> `restoreRecordedSession` (`Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`, near line 387) restores ONE session with `restoreSessionWithHostChecks(id:)` (`SessionSetup.swift`, near line 1191). The Router restores the transcript tree under it, whose children are FORKS. A sub-agent recording lives flat in `<recordingsDir>/<routerId>/<id>`; it is a separate root whose record has `agentSpawn.parentSessionId`. So sub-agent sessions are not restored.

DECISIONS (user, 2026-11-03):
- A restored sub-agent comes back IDLE. It is not started again here (the re-drive task does that).
- TOOLS AND INSTRUCTIONS COME FROM THE CURRENT CONFIG, never from the recording. Changing the tools config is a main reason to kill and resume a session. The recording holds tool names only to report a mismatch. A child is rebuilt from the CURRENT agent definition (`tools`, `disallowedTools`, instructions) and the CURRENT catalog, as a new child would be. If the definition no longer exists, the child fails to restore.
- A child that fails to restore is announced as `unknown` with a reason (the root still resumes). It is in the tree. (Wire part: child sync task.)
- The ACP id of a child is its Router ULID string, as for the root. It is stable.

Do:
1. After the root is restored, find its recorded sub-agent sessions through `agentSpawn.parentSessionId`, at every depth, with the recorded session listing of the Router (`RecordedSessions.swift`: `kind: .subagent`, `parentID`). Do not scan folders by hand.
2. Rebuild each child through FoundationModelsAgents, because only that package builds a child tool roster and instructions from a definition (`AgentSessionMaker.tools(for:as:)` is private; a restore with the root tools would give a child tools it was not allowed). This needs a restore API on `AgentRunner` that reads the record (`agentID`, `agentName`, `slot`, `agentSpawn`), finds the definition in the registry, builds the tools from the current config, restores the Router session, and returns an idle run linked to its caller. BLOCKED BY (other board, no card yet; the user must decide): the FoundationModelsAgents restore API. Do not restore a child with the root tools.
3. Register each child as an ordinary session with the shared session build of the first task (own ACP id, `parentSessionId`, projector, ledger, history sink), parent before child.
4. Do not change the Router or FoundationModelsAgents from this task.

## Acceptance Criteria
- [ ] After a cold resume of a root that had a nested chain of sessions (root, child, grandchild), `sessions` holds the root, the child and the grandchild, each with its parent.
- [ ] Every restored child is idle.
- [ ] A restored child has the tools of the CURRENT definition: change `disallowedTools` between the run and the resume, and the restored child follows the new config.
- [ ] The ACP ids of the children are the same after a second resume.
- [ ] A child whose definition is gone is not restored, and the root still resumes (the failure is kept for the child sync task).
- [ ] `session/close` of the root closes the restored children.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift`: record a session with a nested chain of three sessions with the stub model, resume, check entries, parents, idle, stable ids, config change, missing definition, close.
- [ ] Run `swift test --filter ResumeNestedSessionsTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents