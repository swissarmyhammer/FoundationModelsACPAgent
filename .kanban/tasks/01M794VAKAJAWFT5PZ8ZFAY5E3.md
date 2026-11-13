---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m794xz37nptjb3tfan8q4ny5
  text: |-
    Investigation (2026-11-12, read-only) — verdict (a), with an agent-side variant:
    - Frames 16 and 17 are the first running state of the grandchild and the child state that lists it: the direct result of the grandchild start just before the test sends the resume. In the 9 runs that passed, they came before the request. Both sessions were announced on this connection before frame 15. run6.log has only client times with 1 s precision, so times alone cannot prove it.
    - Every state_update send obeys the hold: `deliverChange` (recorded) goes through `historySink`/`recordAndRoute` (SessionHistory.swift ~300-352); `resendWhenListChanged` and `announceCurrentState` (unrecorded) go through `unrecordedSink`, which reads `route(forSession:)` when it runs (~370-383); `deliver` gives each send with a hold to the hold (~414-430); `route(forSession:)` takes the hold of the nearest owner record (ConnectionTable.swift ~462-472).
    - The window: `historySink` fixes the route at record time. An update recorded BEFORE the take gets the old route with no hold, waits in `post` / `gate.submit` / `deliver`, and its write can occur AFTER the take. On the same connection it arrives between the request and the replay. SessionResumeHot.swift ~28-33 accepts this today.
    Plan (orchestrator): (1) Agent: in `deliver`, when the recorded route has no hold, read the route again; if a hold is now there and its owner is the same connection, drop the update (the replay and `syncCurrentState` give it again; nothing is lost or sent twice). Deterministic test: record a child update before the take, hold its write until after the take, resume on the same connection, and expect no frame of that session before its announcement. (2) Client: frames that the agent wrote before it read the request can still arrive after it; foundationmodelsacpclient-76 makes its validator permit a live update between the request and the first replay frame for a session announced earlier on the same connection.
  timestamp: 2026-11-13T00:29:14.215776+00:00
- actor: claude-code
  id: 01m795cmcwvv61jyd8gs239kz2
  text: 'Client part done (2026-11-12): FoundationModelsACP 9254159 "skip a live update in transit at a resume request". Between a session/resume request and the first update in the stream of the resumed session, SubagentWireTraceValidator skips an update of a session announced earlier on the same connection. An update of a never-announced session is still rule 3; a child state_update after the replay start is still rule 2. Limit: a live update in transit of the resumed root itself cannot be told from the replay start, so it is still checked as replay. Thus the agent fix of this card must also make sure that no live update of the ROOT gets through between the take and the replay (the drop in `deliver` covers the root too). Send the ACPAgent hash to foundationmodelsacpclient-76 for 10 runs, two times.'
  timestamp: 2026-11-13T00:37:14.780356+00:00
- actor: claude-code
  id: 01m798pwcm3p7qnzwpzeq79nvs
  text: |-
    Implement research (worktree par/zfay5e3 on dcc050e):
    - `deliver` (SessionHistory.swift) gets the route that `historySink` read at record time. `unrecordedSink` reads the route when the send runs. Both go through `deliver`, so one re-read there covers the recorded and the unrecorded sends.
    - The replay sends the announcements first (`replay(_:from:sessionId:)` in SessionResume.swift), then the history. It sends no retained `state_update`; the current state of a child comes from the snapshot after the response (`scheduleHotSync`).
    - Test plan: the existing `FrameHoldingTransport` holds the first `subagent_update` frame (the first replay frame). It must start disarmed, because the same connection already carried announcements. `ScriptedPromptFixture.make` gets a `wire` parameter so the first connection can run over the holder. A closed `SessionAnnouncementGate` keeps the send of a text chunk from its record (before the take) until the holder keeps the replay. Then the test opens the gate (the `open` call waits for the send), and releases the replay. The order comes from the gate and the holder, not from a clock.
  timestamp: 2026-11-13T01:35:16.372670+00:00
position_column: doing
position_ordinal: '8180'
title: 'Hot resume on the same connection: a state_update of a child can still come before its announcement (1 of 10 ACPClient runs)'
---
## What
Report of foundationmodelsacpclient-76 (2026-11-12) on ACPAgent 0c1aeaf: `aHotResumeKeepsTheRunningChildRunning` failed 1 of 10 runs (run 6). The test resumes on the SAME connection that owns the tree. Trace: 15 > session/resume <root> request; 16 < <grandchild> state_update; 17 < <child> state_update; 18 < <root> subagent_update(<child>); 19 < <child> subagent_update(<grandchild>); 27 < resume response. Rules 3 and 2 fail at 16 and 17, rule 9 at 17. Trace: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/c6a2f1c1-d86c-4e3e-8e84-1327458d50a2/scratchpad/runs10f/hot-run6.txt (log run6.log in the same folder). d8c0fb1 gave 10 of 10 earlier. testudoapp-75: a resume test that fails 1 in 10 is a defect, not noise.

Two possible causes; find which one first (an investigation runs now and its result goes on this card):
(a) In transit: the agent wrote frames 16 and 17 before it read the request. Then the client test or validator must allow that form (foundationmodelsacpclient-76 can change it), and the agent must prove the order (for example with a deterministic test or telemetry).
(b) A gap in the hold: a `state_update` of a child goes out after the take on a path that the hold (SessionResumeHold, ConnectionTable.route) does not cover, for example a direct or unrecorded send of the state ledger. Then fix the path in the agent.

Related: ^4273b5t (the hold), ^kd5sxrm (take before any wait), ^3dj0y31 (cold resume state; it does not change the hot path).

## Acceptance Criteria
- [ ] The cause is known and recorded (a or b).
- [ ] If (b): no update of a tree session reaches the new connection before its announcement or the response, with a deterministic test that fails before the fix.
- [ ] If (a): a test in this package shows the frames were written before the request was read, and foundationmodelsacpclient-76 changes the validator or test.
- [ ] foundationmodelsacpclient-76 confirms 10 of 10 (twice).

## Tests
- [ ] A deterministic test for the cause.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1