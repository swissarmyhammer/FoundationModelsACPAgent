---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73awvevkjsd799qwhdwnna7
  text: |-
    Data from foundationmodelsacpclient-76 (2026-11-10):
    - Pins of the failing runs: FoundationModelsACPAgent 51332f3e2f459b80cb5984b9c97b3765c607b590, FoundationModelsACP b6b265ca6f75badbde7b2614d8f35b04d0c4e034. Rate: about 1 failure in 3 full runs of `swift test --package-path IntegrationTests` (ACPClient a58423a and 4f95d2f).
    - Violations of SubagentWireTraceValidator, same form in both failures: position 16, `announceBeforeUse` "an update in <childA> before it is announced" and `noHistoricalStateAsCurrent` "a state_update of <childA> before the response is history replayed as current"; position 17, the same two rules for <childB>, and `backgroundList` "background lists <childA> before it is announced". This agrees with the probable cause: live `state_update`s of the running children reach the new connection before the replay announces them. The fix must also keep the rule `noHistoricalStateAsCurrent`: a live state of a child must not go out before the response.
    - Timeouts: `anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall` hit 120 s at AgentNestedScenarioTests.swift:387; `aKilledAgentResumesTheNestedRunWithItsTree` failed the same way in 2 of 5 runs. Each passes in about 3 s when it does not hang, so these are waits that never end. The log has many "A session/update send failed" (ConnectionError) warnings of PromptExecution and no violation. Cause unknown; investigate: a send to the old, closed connection that blocks or is waited for after the take.
    - ACPClient will print the full trace on a validator failure (AgentNestedScenarioTests.swift:60).
  timestamp: 2026-11-10T18:18:02.587931+00:00
- actor: claude-code
  id: 01m73axfm3a6y9tvejxb0bmc1f
  text: The ACPClient task that prints the full wire trace on a validator failure, and the last frames of each connection on a hang, is 01M73AX861R80NS7CQV9T52T9Y (FoundationModelsACPClient board). foundationmodelsacpclient-76 runs the suite several times when this card sends its fix.
  timestamp: 2026-11-10T18:18:23.235410+00:00
- actor: claude-code
  id: 01m73bx1qbhey1rn77spw09f7m
  text: |-
    Cause confirmed (2026-11-10), deterministic test, no clock decides the order.
    - Test: `HotResumeTests.aLiveUpdateOfTheChildDuringTheReplayComesAfterItsAnnouncement`. The second connection runs over `FrameHoldingTransport` (test Support). It keeps the first frame with `subagent_update` (the first replay announcement). So the resume waits after the take, before the replay is out. The test then releases a window hold of the child script. The child sends two text chunks. The test waits until the agent recorded the second chunk (the projector sends one update at a time, so the first send is done). Then the frame goes.
    - Result before the fix: both live chunks of the child reach the new connection before the announcement of the child. Wire order: initialize response, chunk FIRST (child), chunk SECOND (child), then the held announcement. `announcedAt < liveAt` fails.
    - Why: the sink reads the path of the session when the send runs (`ConnectionTable.path(forSession:)`). After `takeSession`, that path is the new connection. The gate of the child is open from the old connection. Nothing holds the live send until the replay is out.
    - Second gap found in the code: the replay tree is a copy of the history that `replayHistory` takes after the awaits of the withdrawal. An update recorded before that copy, whose send runs after the take, goes to the new connection live AND in the replay (sent two times). The sink must bind the route of a recorded update when it records the update.
    - Also: the live `state_update` of the root and of the children must not go out before the response (rule `noHistoricalStateAsCurrent`), and the ledger of the root sends its current state in the same order as its live changes. So a hold that blocks its caller would block the current state of the root before the response (deadlock). The hold must keep the sends in one FIFO for the whole tree and return to the caller at once.
  timestamp: 2026-11-10T18:35:37.579634+00:00
- actor: claude-code
  id: 01m73cksw0nbbdx1td69p1qbp2
  text: |-
    Implementation landed (2026-11-10).
    - New `SessionResumeHold` (Agent/SessionResumeHold.swift): one FIFO for the live sends of the whole tree. A submit while it holds returns at once (a blocking hold would block the root ledger and so the current state before the response). `release()` sends the kept sends in order, then opens in one locked step. `discard()` drops them.
    - `ConnectionTable`: `take(_:by:holding:)` keeps the hold with the owner record of the root. A later take, or `remove` of the owner, discards it. New `route(forSession:)` gives owner + hold in one locked read. New `removeHold(_:of:)`.
    - `historySink` now records and reads the route in one actor step (`recordAndRoute`). The resume takes the session and copies the replay tree in one actor step too. So an update recorded before the take is in the replay and goes to the OLD owner; an update recorded after the take goes into the hold. No update goes to the new connection both in the replay and live. `unrecordedSink` reads the route when the send runs.
    - `resumeLiveSession`: take with a hold, copy the tree, withdraw, replay (`replay(_:from:sessionId:)`), current state direct to the connection (`syncCurrentState(...through:)`, so it is not held), response. After the response: `syncChildren` (direct snapshots), then the release of the hold, then the re-ask of the questions. `onDiscard` of the deferred work discards the hold.
    - ARCHITECTURE.md: the hot resume bullet names `SessionResumeHold`.
    - Tests: HotResumeTests (4 new: order after the announcement, each window update once after the response in order, validator clean across the window, an update recorded before the take goes to the old connection). The 4 fail on the old Sources (checked with a stash) and pass now. SessionResumeHoldTests (8 unit tests of the hold and of the table routes).
    - The two hangs: NOT the hot resume. Both tests do a COLD resume in a new process. Probable cause (about 70 percent, not reproduced): the restored scripted run gets the "process stopped" continue prompt, the new stub backend selects passes only from the current prompt, so the grandchild echoes and goes idle at once, and the ACPClient wait for the short `running` state has no fail condition. The "session/update send failed" warnings are sends to the closed old connection, which throw at once and do not block. Not small, and partly in the client test. Separate card: ^bywxxvm.
    - Gap found: a NEW question of a child in the window goes to the new connection before the replay (requests do not use the hold). Separate card: ^w3nmwmw.
  timestamp: 2026-11-10T18:48:03.200117+00:00
- actor: claude-code
  id: 01m73ckxyqgsemzs2hnebjcstv
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0, 1910 tests in 211 suites passed (1 known issue: the existing withKnownIssue in HarnessSmokeTests), zero compiler warnings (only the SwiftPM "missing creator for mutated node" mlx bundle message of the build system). Files: Sources/FoundationModelsACPAgent/Agent/SessionResumeHold.swift (new), ConnectionTable.swift, SessionHistory.swift, SessionResume.swift, SessionResumeHot.swift, SessionSetup.swift (doc link), Telemetry/RequestTracing.swift, ARCHITECTURE.md, Tests/FoundationModelsACPAgentTestSupport/HarnessWire.swift, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift, SessionResumeHoldTests.swift (new), Support/FrameHoldingTransport.swift (new).
    - open: acceptance item "ACPClient `aHotResumeKeepsTheRunningChildRunning` passes repeatedly" needs foundationmodelsacpclient-76 to confirm. Hangs moved to ^bywxxvm; question gap to ^w3nmwmw.
    - next: /review
  timestamp: 2026-11-10T18:48:07.383960+00:00
- actor: claude-code
  id: 01m73cm6nk5j53pwgge2wj4ewm
  text: 'Note for review: the card says "Keep the history sink unchanged." The record part of `historySink` is unchanged: each update still merges into the retained history before its send, and the gate path is the same. The send part changed: the sink now reads the route in the same actor step as the record (`recordAndRoute`), not when the send runs. Without this, an update recorded before the take and sent after it reaches the new connection two times (replay and live), and the acceptance item "not sent twice" fails; the test `anUpdateRecordedBeforeTheTakeGoesToTheOldConnection` shows it. If the card meant "no change at all to historySink", a person must decide.'
  timestamp: 2026-11-10T18:48:16.307476+00:00
- actor: claude-code
  id: 01m73cmxr43n2xx76k1pvnyz4m
  text: 'Decision of the orchestrator (2026-11-10): the change of the send routing in `historySink` is accepted. The card text "Keep the history sink unchanged" was about the recording of the history, and the recording is unchanged. The routing change is necessary, because without it an update recorded before the take is sent two times (`anUpdateRecordedBeforeTheTakeGoesToTheOldConnection`).'
  timestamp: 2026-11-10T18:48:39.940150+00:00
- actor: claude-code
  id: 01m73cv45dvh5x68e48j1bdwwb
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`, 2 findings (2 confirmed, 3 refuted) — Sources/FoundationModelsACPAgent/Agent/ConnectionTable.swift:452 (duplication/duplication), Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:274 (swift/concurrency). The routing change in `historySink` is an accepted decision and the engine did not report it.
    - next: /implement the two items in "Review Findings (2026-11-10 12:48)", then /review again.
  timestamp: 2026-11-10T18:52:03.117517+00:00
- actor: claude-code
  id: 01m73cxznkkwdkb2w5g69n4q9p
  text: |-
    Work on the findings of 2026-11-10 12:48 (2026-11-10).
    - Finding 1: new private static `ConnectionTable.nearestRecord(in:along:) -> SessionId?`. It is the one definition of "the nearest session in the lineage that has an owner record". `owner(in:along:)` returns `nearestRecord(...).flatMap { state.owners[$0] }`. `route(forSession:)` gets the record from the same helper, then reads the owner and the hold. No other lineage lookup is in the file (the reads in `take` and `claim` read the record of the session itself, not a lineage).
    - Finding 2: `resumeTraceAcrossTheWindow` cancels the `resume` task on each exit (`defer { resume.cancel() }`). The same cause in the new tests: `anUpdateRecordedBeforeTheTakeGoesToTheOldConnection` cancels the `recorded` task and the prompt task of the tree on each exit; the three window tests cancel the prompt task of the tree on each exit. A cancel after the success path is a no-op, because the task is done then. `waitForText` already cancels its limit task with `defer`, and awaits its `delivered` task on each path. SessionResumeHoldTests.swift makes no unstructured `Task`. The old helpers (`openPrompt`, `resumeTrace`) and the old tests are not changed: the review skill drops findings that ask to refactor tests that already existed.
  timestamp: 2026-11-10T18:53:36.819653+00:00
- actor: claude-code
  id: 01m73d53revj9mcenshn6434kx
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0, 1910 tests in 211 suites passed (1 known issue: the existing withKnownIssue in HarnessSmokeTests), zero compiler warnings (only the SwiftPM "missing creator for mutated node" mlx bundle message of the build system). Files: Sources/FoundationModelsACPAgent/Agent/ConnectionTable.swift, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift. Both items of "Review Findings (2026-11-10 12:48)" are checked.
    - note: the change of ConnectionTable is a refactor with the same behavior; the existing SessionResumeHoldTests and HotResumeTests cover `owner(of:)` and `route(forSession:)`, so no new test was added.
    - next: /review
  timestamp: 2026-11-10T18:57:30.382620+00:00
- actor: claude-code
  id: 01m73d7ej59gdd6dvpgvde1vgs
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1201c7f) — 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. The two prior findings (ConnectionTable.swift duplication, HotResumeTests.swift concurrency) are checked and the fix commit has no new finding.
    - next: none. The task moved to done.
  timestamp: 2026-11-10T18:58:46.981195+00:00
- actor: claude-code
  id: 01m73enx7q05g0f94qxr8yx7b7
  text: 'Acceptance confirmed by foundationmodelsacpclient-76 (2026-11-10): 10 of 10 full runs of `swift test --package-path IntegrationTests` pass with FoundationModelsACPAgent 89152e3 (only the ACPAgent pin moved from 728276c). `aHotResumeKeepsTheRunningChildRunning` passed 10/10 (1.6–1.9 s). Before the fix it failed in about 1 of 3 runs. Logs: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/c6a2f1c1-d86c-4e3e-8e84-1327458d50a2/scratchpad/runs10/. The two hang tests also passed 10/10, but their faults are probably only not hit: the killed-agent case is the prompt-record race of card 01M73DP5EY59X102WFGYJJ4MR5.'
  timestamp: 2026-11-10T19:24:09.335134+00:00
position_column: done
position_ordinal: ffffcb80
title: 'Hot resume: a live child update can reach the new connection before the replay announces the child'
---
## What
Report from testudoapp-75 and the FoundationModelsACPClient integration suite (their task 01M737WW16, 2026-11-10): `aHotResumeKeepsTheRunningChildRunning` sometimes fails with the trace "an update in <session> before it is announced". After a hot resume, a session update of a running child reaches the new connection before its `subagent_update` announcement. The same suite also has timeouts in `anOrderlyQuit…` and `aKilledAgentResumes…`. The fault is there also before the latest ACPClient changes. The hot resume is the evidence of ACPA-11, and TestudoApp ^yf4w457 resumes a session.

Probable cause (from the code, 2026-11-10; confirm it first):
- `resumeLiveSession` (`Sources/FoundationModelsACPAgent/Agent/SessionResumeHot.swift`) calls `takeSession` first, then withdraws the open questions, then `replayHistory`, then `syncCurrentState`.
- The `SessionAnnouncementGate` of a child (`SessionAnnouncementGate.swift`) opened at the first announcement, on the OLD connection. It stays open. After `takeSession`, each live update of the running child goes to the new connection at once.
- The announcement of the child comes later, in the replay of the parent history (`SessionResumeReplay.swift` `announcements`). Thus a live child update can come before it.

1. Reproduce it in this package with a deterministic test: a parent with a running child that sends updates under a gate that the test controls (gated stub model). Resume from a second connection, and release a child update between the take and the replay. Expect the order fault. The test must not depend on time.
2. Fix: the new connection must get each live update of a tree session only after the replay has announced that session. For example, for the hot resume, hold the live sends of each session of the tree (a per-connection gate, or close and re-open the gates of the children for the new path) from the take until the replay of the announcements is out, then flush them in order. Keep the history sink unchanged.
3. Check the two timeouts (`anOrderlyQuit…`, `aKilledAgentResumes…`). Get the repro from session foundationmodelsacpclient-76. If they have a different cause, record it on this card and make a separate card.

## Acceptance Criteria
- [ ] After a hot resume, the new connection never gets an update of a child before the announcement of that child.
- [ ] No live update of the tree is lost or sent twice across the take and the replay.
- [ ] The ACPClient test `aHotResumeKeepsTheRunningChildRunning` passes repeatedly (foundationmodelsacpclient-76 confirms).

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/HotResumeTests.swift`: the deterministic order test above, which fails before the fix and passes after it.
- [ ] A test that each live update sent between the take and the end of the replay reaches the new connection one time, in order.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1

## Review Findings (2026-11-10 12:48)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 9 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Agent/ConnectionTable.swift:452` `duplication/duplication` — The new `route(forSession:)` repeats the nearest-ancestor-with-an-owner lookup that `owner(in:along:)` already implements at line 385, as `lineage.lazy.compactMap { state.owners[$0] }.first`. Two copies of the rule "nearest session in the lineage that has an owner record" must stay in step. If one changes and the other does not, `owner(of:)` and `route(forSession:)` can name different owners for the same session, which breaks the single-locked-read guarantee the doc comments describe. Add one private static helper, for example `nearestRecord(in state: State, along lineage: [SessionId]) -> SessionId?`, that returns the first session in the lineage with an owner record. Have `owner(in:along:)` return `nearestRecord(...).flatMap { state.owners[$0] }`, and have `route(forSession:)` use the same helper to get the record, then read the owner and the hold from it. The two lookups then share one definition of the rule.
- [x] `Tests/FoundationModelsACPAgentTests/HotResumeTests.swift:274` `swift/concurrency` — The resume request is started in an unstructured `Task`. The task is awaited only on the success path. If `waitUntilRecorded` or any earlier step throws, the `Task` is never awaited or cancelled, so the request keeps running after the test has already failed. Cancel the task on the throw path, for example with `defer { resume.cancel() }` placed after the task is created, or move the work into a `withThrowingTaskGroup` so the child task is awaited or cancelled on every exit.