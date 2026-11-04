---
comments:
- actor: wballard
  id: 01m6gk7vbapnfa9v3zpe2xvekc
  text: 'UPDATE (user decision, 2026-11-03): the Router write-ahead record of a tool call is wanted. Card on the Router board: 01M6GK7RHHHC6B6QMJ25FT1QDT. Still undecided and without a card: the Router claim API for orphan runs, and the FoundationModelsAgents adopt call. Order of questions to the user: one at a time.'
  timestamp: 2026-11-03T11:38:17.322457+00:00
- actor: wballard
  id: 01m6gk8k87fp83cdcg2sny7e4a
  text: 'UPDATE: the Router claim-API card exists: see the Router board, title "Let a host claim orphan runs at restore". It depends on the write-ahead card. The FoundationModelsAgents adopt call still has no card.'
  timestamp: 2026-11-03T11:38:41.799615+00:00
- actor: wballard
  id: 01m6gkm2x38at4eed30b449m1b
  text: 'DECISION (user, 2026-11-03), gap 2: the re-drive of interrupted children starts AFTER the resume response is sent. The agent restores and replays the whole tree, sends the response, and only then sends the "continue" mail to the interrupted children (children first). Everything after the response is live for the client, so replay and live updates never mix. Cost accepted: work starts only after the whole restore. Acceptance criteria to add: no re-driven child sends any update before the resume response; the first update of a re-driven child follows the response; a test with a slow restore of a depth 3 tree checks the order of the wire messages. Held updates (starting early) are NOT wanted.'
  timestamp: 2026-11-03T11:44:58.275984+00:00
- actor: wballard
  id: 01m6gkyt7rmwr07tw7kzye14gn
  text: |-
    DECISION (user, 2026-11-03), SUPERSEDES the earlier comment "a child session knows its parent, and its replay ends with its OWN history" (the per-child end on a state_update snapshot before the response). That text misread the subagents RFD. FOLLOW ACP (RFD "Subagent Sessions", section replay and resume):
    - All history of the tree (associations and child history) is sent BEFORE the resume response ("All history selected for this replay MUST be sent before the response"). The response completes the best-effort child replay. A child replay ends at the response. There is no per-child end marker in ACP.
    - When replay is requested, the successful response is the freshness boundary for child work state and mutation-capability snapshots. Snapshots sent before the response are historical: they MUST NOT authorize client mutations and MUST NOT confirm current activity. Current snapshots are sent AFTER the response. Without a replay, announcements and snapshots may come before or after the response.
    - The ancestor chain is announced parent before child, before any use of a child in live traffic. Replay MUST NOT reissue permission, elicitation or other agent-to-client requests.
    AGENT: replay (associations, child history, no child state_update as a current fact) -> parent current state_update snapshot (with the `background` list) and session info -> response -> current `subagent_update` snapshots of every child (state and capabilities) -> only then any re-drive (a snapshot must precede a running update of the same child so a delayed copy cannot overwrite a newer state). A cold-restored child snapshot is `idle`. Do not echo a synthetic user_message for a re-drive mail (agent-started foreground work needs none).
    CLIENT: on resume the client invalidates cached child work state and capabilities. Child models made during the replay are `.replaying` and end their replay at the RESPONSE of the root request. After the response a child is UNCONFIRMED (shown as unknown, effective capabilities empty) until its first current snapshot; child controls (cancel) stay disabled until then, and until the resume has succeeded. Everything inside the replay phase is history: no notification, sound, attention mark or auto action. Add `SessionModel.isWorkStateConfirmed` (or an equivalent) as an observable.
    Acceptance criteria to add: no child current snapshot before the response in a replay; every child gets a snapshot after the response; a child is unconfirmed and not cancellable between the response and its snapshot; the re-drive start follows the snapshots; a replay with no replayFrom still announces the children and sends current snapshots; no needsAttention or notification is raised by replayed content.
  timestamp: 2026-11-03T11:50:49.848808+00:00
- actor: wballard
  id: 01m6gmvgvhaq71v7958tpnvazf
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    Mark this task stuck until all three blockers are decided: Router write-ahead (01M6GK7RHHHC6B6QMJ25FT1QDT), Router claim API (01M6GK8K45DRDT6B4SHB9V60ED), and the FoundationModelsAgents restore/adopt API (no card yet). A batch run (/finish) must not start it. Add a fallback: if the Router refuses the claim design, the child result is delivered as run mail for a lost run, and the original call stays lost (the weaker version the user rejected). Ask the user before taking that fallback.
  timestamp: 2026-11-03T12:06:30.513553+00:00
- actor: wballard
  id: 01m6gns7kak85vyveymcth70w1
  text: |-
    DECISION (user, 2026-11-03): if an agent session is DONE, there is nothing to restore. When an agent finishes, its session is ended and removed. Agents runs stay ONE-SHOT (no idle state in AgentRunState).
    EFFECT ON THIS PLAN:
    - A resume restores ONLY the sub-agents that were still working (interrupted) when the process stopped. Finished children are not restored and are not announced as part of the restored tree.
    - The set to restore is the set of orphan runs of the parent (a run with a non-terminal journal event and no completed). This is the same set that the Router claim card (01M6GK8K45DRDT6B4SHB9V60ED) lets a host claim. The two tasks are one flow: claim, restore, continue, complete the original call.
    - This replaces: "restore every recorded sub-agent session, found through agentSpawn.parentSessionId, all idle" (cold resume), and "a restored child comes back idle and can get new work later". A restored interrupted child is announced idle in the first snapshot after the response, then goes running when it is continued (re-drive), after the response. It ends once; then it is removed like any finished child.
    - The Agents restore API (card 01M6GNHC0MV9FBT33Z9DTT5TVA on the Agents board, rewritten) restores and continues in one call.
    - To verify first: how the host finds the child session of an orphan run after a crash (orphan RunKey -> SDK tool call id in the journal -> recorded child with agentSpawn.parentToolCallId). The runner map from completion token to run is in memory and is lost in a crash.
    - Open (the user decides): how the live ACP tree tells the client that a finished child is gone. ACP has no removal message; a child stays an idle association.
  timestamp: 2026-11-03T12:22:44.074831+00:00
- actor: wballard
  id: 01m6gptd264ychsj1yabkm6s2f
  text: |-
    DECISION (user, 2026-11-03), from the review by the Agents session: a finished agent session is NOT removed from disk by the Router (close() unregisters it but keeps the recording; the record has no ended field). So "a finished child is not restored" needs a marker. The user chose: MARK THE RECORD AS ENDED (the recording stays for history). Router card: 01M6GPT1DM4KZNTT31NMQ0962J "Mark a session record as ended, so a host can tell a finished sub-agent run from an interrupted one". The host (FoundationModelsAgents) sets the marker when a run reaches a terminal state.
    EFFECT: this task and the re-drive task are BLOCKED by that card for the rule "finished children are not restored". Until it is done, the only way to find interrupted children is the orphan scan of the parent, which misses a child that crashed before its first journal event. Other Router needs of the restore (not decided, no card yet): a public lookup of recorded children by agentSpawn.parentToolCallId and a public orphan scan that does not need the restore of the parent; restore parameters for parentCall, the compaction settings and mailOnlyAnswerLimit (these come from the recording today, against the user rule that config comes from the current config).
    The chain to find the child of an orphan run is shorter than first written: orphan RunKey.correlationID (the completion token) equals the child agentSpawn.parentToolCallId, with parentSessionId equal to the parent. The SDK tool call id is not part of it.
  timestamp: 2026-11-03T12:40:51.014175+00:00
- actor: wballard
  id: 01m6hccrf8cbrwt2mm1zwg2014
  text: |-
    MULTITOOL AUDIT (read-only, 2026-11-03) items for the restore in this task:
    (a) Shell records are memory only: after a restore, handles of earlier shell commands are gone (getLines(oldToken) throws unknownCommand). The continue message to a restored run must say: earlier shell command handles and background shell output are no longer available; start the command again if you still need it.
    (b) The snapshot verbs need the session key reopened after a restore: SnapshotsContext reads HookSession.current and the default key is the session id; if the host does not reopen it the verb returns unavailable. The host must reopen the key (SnapshotSessionKeys.record for the restored session and for each restored child, with the hook lineage of its root) BEFORE the first submission of each restored session. Add a test.
    (c) The Registry (MCP servers, shell store, file context) is rebuilt in the new process before makeSessionTools: the agent package builds its registry at startup, so restored runs are built from the CURRENT registry; a Multitool accessor for the current registry is being added on the Multitool board (card pending): use it when it lands.
    (d) A restored run must not reuse the completion tokens of Multitool inner runs (status and cancel of an old token answer "no run under that handle"). The restored agents call keeps ITS OWN old token (that is the claim); inner shell and runCode tokens are not restored.
    (e) A crash can leave shell child processes and stdio MCP servers running; a Multitool card reaps them at store init.
  timestamp: 2026-11-03T18:57:52.616149+00:00
- actor: wballard
  id: 01m6hg2n9ebr8qw91w21tgghs4
  text: |-
    HOOKS REPORT ITEM (independent, 2026-11-03): FoundationModelsRouter Session/SessionHooks.swift near lines 172 to 175: when the parent is not open, the hook key of a sub-agent is the id of its parent. The ACP roots use the PROJECT key (Agent/AgentHooks.swift near 71 to 83, SessionResume.swift near 209). A child that is restored BEFORE its root, or whose root key is not passed, gets a different key, so a separate snapshot timeline for one work tree.
    RULES FOR THIS TASK: (1) restore the ROOT session first, with its project hook key (hookSessionKey), and only then call the Agents restoreInterrupted facade, which restores caller-first, so every restored child finds its root open and gets the root key; (2) check how the host passes hookSessionKey (SessionSetup.swift near 1178, SessionResume.swift near 399) for restored children and fix it if a child can be restored without it; (3) write a test: after a cold resume, the hook key of the root, of a restored child and of a restored grandchild is the SAME project key, and the snapshot timeline is one; also the same test for the SnapshotSessionKeys record of each restored session; (4) SessionEnd at an orderly quit is sent for runs that are suspended (the Hooks session adds a reason: completed, suspended, released; the Router sets it): a snapshot or cleanup hook of this package must not treat a suspended SessionEnd as done; check AgentHooks.swift and the snapshot hooks for work on SessionEnd and test that a quit does not delete the timeline.
  timestamp: 2026-11-03T20:02:15.982124+00:00
- actor: claude-code
  id: 01m6knm260drbc5w1y6r355fqv
  text: |-
    ### implement — stuck
    - evidence: worktree /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent-wt-redrive (branch wt-redrive, no commit, no code change). `swift build --build-tests` fails in the test target: Tests/FoundationModelsACPAgentTests/Support/HookLayeredModelLoader.swift:26 "cannot find 'HookLayeredLLMContainer' in scope". Cause: Router moved HookLayeredLLMContainer into the main Router target (the separate task ^c1asjzd, fix on branch wt-router). The rule for this run says: do not fix here, stop.
    - research done: the Agents API exists now (AgentRunner.claims(of:directory:), restoreInterrupted, RestoreReport.resumeAll()). The host already restores idle children (SessionResumeNested.swift) and sends current child snapshots after the response (scheduleChildSync / syncChildren in SessionResumeChildSync.swift). Plan: after syncChildren sends the snapshots, call report.resumeAll() (children first). Put it in a new file; test file RedriveInterruptedRunsTests.swift reusing ResumeNestedSessionsTests fixtures (recordShutDownChain, resumeRoot).
    - next: merge or finish ^c1asjzd, then rerun this task.
  timestamp: 2026-11-04T16:17:37.984542+00:00
- actor: claude-code
  id: 01m6kqsvsdjneynacc9b355brp
  text: |-
    ### implement — changed
    - evidence: commit da67402 on branch wt-redrive (worktree FoundationModelsACPAgent-wt-redrive), not pushed, not merged. 6 files: Sources/FoundationModelsACPAgent/Agent/SessionResumeRedrive.swift (new: redriveInterruptedRuns(of:)), Sources/FoundationModelsACPAgent/Agent/SessionResumeChildSync.swift (the closure of scheduleChildSync calls it after syncChildren), Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift (new, 8 tests), Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift (changed test), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift (new, real binaries), IntegrationTests/.../Support/SpawnedACPAgent.swift (killAndWait). No change to SessionSetup.swift or ConfigOptions.swift. No sibling package changed.
    - tests: RED first (6 of 8 failed, no re-drive). GREEN: `swift test --filter RedriveInterruptedRunsTests` 8 passed. Filtered resume suites (Redrive, ResumeNested, ResumeChildSync, SessionResume, ResumeSync, ResumeLiveSession) pass after the change below. Full `swift test` in the worktree: 1780 tests in 195 suites passed, 1 known issue (HarnessSmokeTests, intended), 0 warnings of this code. Integration test: run from a copy of IntegrationTests under a directory named FoundationModelsACPAgent (the IntegrationTests package names its parent by directory name, so it does not resolve inside the worktree folder wt-redrive): RedriveInterruptedRunsProcessTests passed (1.8 s).
    - design: after syncChildren sends the snapshots, redriveInterruptedRuns calls report.resumeAll() (Agents starts the children first). It starts nothing when the root closed or its connection is gone.
    - finding 1 (needed code): a restored caller holds the claimed run of its child since the restore, so its Router session has phase "working" before the ACP ledger took the idle snapshot, and Router sends no new workStarted when the caller works again. The wire then showed the middle child as idle (with the grandchild in its background list) while it worked. So redriveInterruptedRuns first calls stateLedger.workStarted(on: run.id) for each restored run; the Router workEnded clears it (test: everyRestoredChildIsIdleWhenItsRedrivenRunEnds). Test eachRedrivenSessionShowsRunningBeforeItWorks was red for the child before this.
    - finding 2 (changed existing test): ResumeNestedSessionsTests.everyRestoredChildIsIdle assumed that nothing starts the children. It is now everyRestoredChildIsIdleWhenItsRedrivenRunEnds. The idle snapshot after the response stays covered by ResumeChildSyncTests.
    - finding 3 (test limit): the order "children start before callers" is seen on the wire as: grandchild shows running before the child plays its first text. The first text of each session comes when its first pass ends, so the order of two texts is a race (tried, failed). The order of the start itself is the Agents resumeOrder (reversed tree order).
    - finding 4 (integration test): the orderly stop (stdin close or SIGTERM) with an open root prompt cancels the prompt and with it the child; the child then ends as `finished` and is not restorable. Without an open prompt the child is cancelled after the run grace (about 5 s). So the integration test kills the first process with SIGKILL. This is a real behaviour to decide on (a user quit while a sub-agent works loses the run); I did not change it, it is outside this card. A card may be wanted.
    - finding 5: at the end of the second process stderr has one MailRefusal line (inbox file of the root did not deliver). It happens at the shutdown; the original call completed before it.
    - next: review
  timestamp: 2026-11-04T16:55:45.197432+00:00
- actor: claude-code
  id: 01m6kr1cqp2g8brafq76akb7vn
  text: |-
    ### review — findings
    - evidence: review sha 2687686~1..2687686; 6 findings, 6 confirmed, 0 failed, 0 skipped (run complete). Files: RedriveInterruptedRunsProcessTests.swift:164,193,233; RedriveInterruptedRunsTests.swift:86,191,197
    - next: implementer fixes the 6 open items, then /review again
  timestamp: 2026-11-04T16:59:51.926276+00:00
- actor: claude-code
  id: 01m6krr9057nhak9cj3tq91cx1
  text: |-
    ### implement — stuck
    - evidence: 5 of 6 findings fixed in the working tree on main (not committed). Files: Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift (new shared readResumeTrace(...timeout:whileRunning:), WireTraceEvent.isAgentText(containing:on:), SessionUpdate.agentMessageText), Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift.
    - fixed: RedriveInterruptedRunsTests:86 (`var spoken: Set<SessionId> = []`, same for `running`); :191 (`try #require(ULID(ulidString:))`); :197 (`try await directory.runStatuses`, no `try?`); integration :193 (timeout reader moved into test support, used by both `resume` and `resumeAndRedrive`; the `try? Task.sleep` is gone too, the sleep error is handled in a do/catch); integration :233 (one shared `isAgentText`; the duplicate `SessionUpdate.text` is gone too).
    - tests: `swift test --filter RedriveInterruptedRunsTests` 8 passed. Full `swift test`: 1780 tests in 195 suites passed, 1 known issue (HarnessSmokeTests, intended), exit 0.
    - BLOCKER, finding 1 (integration :164, match the completed call by id and assert success): done in the test (the id of the first process is recorded; completed is matched by id and status completed). The test now FAILS, and the failure is a product gap, not a test error. Wire facts: in the first process the agents call has the id `scripted-call-1` (SDK id, in progress). After the cold resume the root replay holds NO agents call at all, and the completion that arrives after the re-drive has the completion token (a ULID) as its id, with no earlier in-progress update. So the client never sees the original call complete: the call `scripted-call-1` stays in progress, and an unknown completed call appears. This contradicts acceptance criterion 4 ("one agents tool call from in progress to completed across the restart"), which the old weak check hid. Cause in this package: the RunCallJoinTable (SDK id to token) is empty after a restart, and the replay of the root does not project the open call. Router main has the write-ahead `toolCallStarted` marker and turns it into a `.toolCalls` entry with a placeholder output at restore (WriteAheadMarker.swift, OpenToolCalls), but the ACP host does not read it (no use of toolCallStarted in Sources).
    - decision needed from the user: build the host feature (replay the open agents call with its SDK id as in progress, and rebuild the join SDK id to token at restore so the completion reuses the id). It is new work beyond the six findings and may touch the replay files. I did not weaken the assertion and did not mask it with a known issue.
    - note: IntegrationTests/Package.resolved (gitignored) pinned an old Router (bb52caa) and did not build; I ran `swift package update` there (now 899e6eb). No tracked file changed by that.
    - boxes: findings 2 to 6 flipped to [x]; finding 1 stays [ ].
  timestamp: 2026-11-04T17:12:21.765781+00:00
- actor: claude-code
  id: 01m6ksed9b4341jwtnf20vwzwc
  text: |-
    ### implement — changed
    - evidence: working tree on main, not committed. New: Sources/FoundationModelsACPAgent/Agent/SessionResumeOpenCalls.swift (restoreOpenCalls(of:)). Changed: SessionResumeNested.swift (one call), SessionResume.swift (replay uses the entry history of the root, so the added call is replayed), Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift (2 new tests), plus the earlier finding fixes (WireTraceReading.swift, the integration test). SessionSetup.swift and ConfigOptions.swift not touched. No sibling package changed.
    - fix: for each restored run, the host reads the Router write-ahead marker (toolCallStarted) of the call from the journal of its caller. (1) It rebuilds the join SDK call id to completion token in the caller projector table and places the hold on the final status, so the completion after the re-drive goes out on the original call id and after the last child update. (2) When the retained history lacks the call (a killed process never wrote it), it adds the call as in progress with the link to the child, and the announcement of the child with the link to the call, so the replay shows the call before the response and announces the child before any update in its stream (validator rule 3).
    - API note: Router keeps ToolCallPayload and TranscriptEntryPayload.toolCalls internal. The host reads the calls through the public Codable form of the entry. A public accessor on TranscriptEntryPayload.toolCalls would be cleaner. No sibling change made.
    - tests: RED first: theCompletionOfTheRootCallHasNoStrayId and theReplayOpensTheOriginalCallWhenNoHistoryWasWritten both failed (stray completion on a ULID id, no replayed call). The second needed the hold and the announcement after the first fix (validator violations rule 3 and rule 8). GREEN: both pass, SubagentWireTraceValidator gives no violation. Filtered resume suites passed. Full root `swift test`: 1782 tests in 195 suites passed, 1 known issue (HarnessSmokeTests, intended), no warnings of this code. One earlier full run showed one failure, OrderlyShutdownTests.aShutdownEndsThePromptOfTheRootAsInterrupted (stopReasons expectation); the next full run passed it. Not touched by this change, looks like a flake; not investigated.
    - integration test: `swift build --build-tests` in IntegrationTests succeeds. NOT RUN, by the user's order (integration tests are for CI). So finding 1 stays [ ] until CI shows the integration test green. The live-model suites are in the IntegrationTests package, so they were not part of the root run.
    - next: review
  timestamp: 2026-11-04T17:24:27.051395+00:00
- actor: claude-code
  id: 01m6kt0cmrnsn6czqbtakgyx82
  text: |-
    ### review — findings
    - evidence: review sha 2687686~1..86a8726; 3 findings, 3 confirmed. Finding 1 of the 10:56 review (RedriveInterruptedRunsProcessTests.swift:164) judged by reading: the test records the id of the original call and matches by id and by status completed (isCompletedCall); lost reports another status (ACPEventTranslator.swift:52), so the check is strong. Box checked. Integration test not run (CI only).
    - open: SessionResumeOpenCalls.swift:115 (swift/preconditions); RedriveInterruptedRunsTests.swift:48 (reuse/reuse); RedriveInterruptedRunsTests.swift:385 (test-integrity/no-test-cheating)
    - next: fix the 3 open findings.
  timestamp: 2026-11-04T17:34:16.216846+00:00
- actor: claude-code
  id: 01m6kt7r4bcf2gkfpcwvj2e1b3
  text: |-
    ### implement — changed
    - evidence: working tree on main, not committed. Files: Sources/FoundationModelsACPAgent/Agent/SessionResumeOpenCalls.swift, Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift, Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift.
    - finding 1: no assertionFailure, no empty default. The meta link now comes from a helper `link(toChild:)` with do/catch, logger.error naming the run, and the field stays omitted (.unchanged) on failure. Same pattern as the existing announcement code. Same cause removed: the `try?` on the rawInput decode is now `rawInput(of:child:)` with the same log.
    - finding 2: `isResumeResponse` is now a public extension property in WireTraceReading.swift; used by responsePosition, readResumeTrace and the process tests (the private copy is deleted).
    - finding 3: theCompletionOfTheRootCallHasNoStrayId and theReplayOpensTheOriginalCallWhenNoHistoryWasWritten now `#require` a first completed call (new Wire.firstCompletion(on:)) before the stray check.
    - tests: `swift build --build-tests` ok; `swift test --filter` Redrive, ResumeChildSync, ResumeNested: 42 tests passed. IntegrationTests `swift build --build-tests` ok, not run (CI only).
    - next: review
  timestamp: 2026-11-04T17:38:17.355235+00:00
depends_on:
- 01M6GJPPXWKQJ9E6SK5WD0CWZ7
- 01M6GM17VHZSWD4G2J27WTA3JT
- 01M6KGEQVH2T73SR32CD6VZDKG
position_column: doing
position_ordinal: '8880'
title: Re-drive interrupted nested runs after a cold resume, children first, completing the original agent tool call
---
## What
After a cold resume the restored sub-agents are idle (previous task). This task gets the interrupted work going again (user, 2026-11-03: "when I resume I want it to get back to work"; leaning to option B: every interrupted session, children first).

Design (user decisions):
- The result of a re-driven child must complete the ORIGINAL `start agent` tool call (the same tool and `correlationID`) of its caller. It must not arrive as a stray message.
- The tool call is in the transcript of the caller. (The user requires this. It is NOT true today: see the blocker.)
- Order: children first. A parent run waits for its child.
- If a child cannot be re-driven, the original call ends as `lost`.

Steps (host side, this package): find the interrupted runs of the restored tree; send each interrupted child one mail ("The process stopped. Continue your work."); when it ends, the final message completes the original run of its caller; the client sees the `agents` tool call go from in progress to completed across the restart; the state of each session shows running again.

BLOCKERS (outside this board, no card on the Router or Agents board yet, the user must decide):
1. Router, facts from the Router session (2026-11-03): the `.toolCalls` entry is written at the END of the submission (`finishSubmission`, `Session/RoutedSessionActorRecording.swift:34`, `recordTranscriptDelta` line 280). After a crash during a tool run the run journal is on disk but the tool call entry is not. A write-ahead write does not exist; it would have to come from the tool-mount layer (`ToolMounting.makeSessionMounted`), because reading `LanguageModelSession.transcript` between tool-loop passes aborts the process. A real design task in the Router.
2. Router: no claim API exists. `Recording/SessionTreeRestoration.swift:493-499` posts a `.lost` for each orphan run unconditionally. A possible shape (not decided): a restore parameter `claimingRuns: Set<RunKey>` and a host contract to post `.completed` or a lost event at close.
3. FoundationModelsAgents: `AgentRunner` must rebuild a run (idle) around a restored child session with the original completion token, and complete the original run when the child ends. An adopt call; no card yet.

Do not start this task until the user has decided the Router and Agents cards.

## Acceptance Criteria
- [x] After a cold resume, an interrupted nested child runs again and its final message completes the original `start agent` call of its caller; the call is not `lost`.
- [x] Children are re-driven before their parents.
- [x] A child that cannot be re-driven ends its original call as `lost`, and the root still resumes.
- [x] The client sees one `agents` tool call from in progress to completed across the restart, and `running` state on each re-driven session.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift`: stub model, kill and restore, order, completion of the original call, fallback to lost.
- [x] An integration test in `IntegrationTests` with the real `acp-agent` binary.
- [x] Run `swift test --filter RedriveInterruptedRunsTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-04 10:56)

> Scope: `review sha 2687686~1..2687686` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 0 not reviewed.

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift:164` `test-integrity/no-test-cheating` — The test is named to prove that the original agents call of the root completes, but line 164 only checks that some completed tool call exists on the root stream (line 162 matches any call by status, not by call id). A call that completes as lost, or an unrelated completed call, would pass. The sibling test in RedriveInterruptedRunsTests.swift checks for .succeeded and rejects .lost, so this check is weaker than the claim it supports. Match the completed call by its id (the id of the original agents call recorded in the first process) and assert that its outcome is the success outcome, not merely that a completed call exists on the root stream.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift:193` `reuse/reuse` — The `resume` helper builds the same timeout task that cancels a reader after a fixed sleep. The unit test target has the same pattern, so this bounded-wait logic is duplicated across two targets. Move one shared reader-with-timeout helper into the `FoundationModelsACPAgentTestSupport` module, which both targets import. Call it from this `resume` and from `resumeAndRedrive`.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/RedriveInterruptedRunsProcessTests.swift:233` `reuse/reuse` — `isText` repeats the logic of `isRedriveText` in the unit test target. Both are `WireTraceEvent` extensions that check a text chunk on one session stream. The two copies can drift, and a fix to one will miss the other. Move one shared `WireTraceEvent` text-on-session helper into the `FoundationModelsACPAgentTestSupport` module, which both targets import. Both files then call it with their own marker text.
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift:86` `swift/idioms` — The empty Set variable uses a constructor call. The idiom is a literal with a type annotation. Write `var spoken: Set<SessionId> = []`.
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift:191` `completeness/public-output-contract` — When the session id is not a valid ULID, `completedOutcomes` returns an empty list without an issue. A caller that waits for `.succeeded` or `.lost` then fails with a generic assertion, and the bad id is never reported. Replace the silent return with `try #require(ULID(ulidString: session.rawValue))`, or record an issue that names the session id, so the test fails at the cause.
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift:197` `completeness/public-output-contract` — The error from `directory.runStatuses(of:)` is silently replaced by an empty dictionary with `try?` and `?? [:]`. When the journal cannot be read, the poll keeps going until its limit and the test then fails on a missing outcome, not on the read error. The cause is hidden from the person who reads the failure. Use `try await directory.runStatuses(of: id)` so a read error ends the test at once with its cause. If polling must tolerate a transient read error, record the last error and report it with `Issue.record` when the poll limit is reached.


## Review Findings (2026-11-04 11:24)

> Scope: `review sha 2687686~1..86a8726` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 14 not reviewed.

> 14 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 14 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResumeOpenCalls.swift:115` `swift/preconditions` — Silent default for an unexpected encoding failure. If `inject(into:)` fails, the meta is replaced by an empty object with no record, so the link of the call to its run is lost without any trace. Use `do`/`catch` around the `inject(into:)` call. In the catch, call `assertionFailure` and write a `logger.error` line that names the run, then keep the empty default.
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift:48` `reuse/reuse` — `Wire.responsePosition` re-implements the response check inline as a closure with `if case .resumeResponse`. The same check exists as `isResumeResponse` in the process test file, and `WireTraceReading.swift` already holds the shared trace helpers. The check now lives in three places. Move `isResumeResponse` into `Tests/FoundationModelsACPAgentTestSupport/WireTraceReading.swift` as a `public` extension property, then use it from `responsePosition` and from the process tests.
- [x] `Tests/FoundationModelsACPAgentTests/RedriveInterruptedRunsTests.swift:385` `test-integrity/no-test-cheating` — The test name says the completion of the root call has no stray id, but the only assertion is that the stray list is empty. If the root call never completes, the read ends at the timeout, the stray list stays empty, and the test passes. The test does not prove that a completion arrived. This is a weak assertion that cannot fail when the behavior is missing. Add an assertion that a completed call exists on the root stream before checking for strays, for example `#expect(wire.trace.contains { $0.isCompletedCall(...) })`, or use `#require` on the first completion index. Keep the stray-id check after it.
