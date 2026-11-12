---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73q2ng3tf3j7geazm18a261
  text: 'Priority: top, directly after ^1et93gh (testudoapp-75, 2026-11-10). More suspects: ACPA-20b 8d7c456 (the start of a restored run), and ^yjj4mr5 23deba2 changes only tests. Bisect between 89152e3 and 4fd6b94 if the cause is not clear from the code, with the deterministic test as the check.'
  timestamp: 2026-11-10T21:50:56.003143+00:00
- actor: claude-code
  id: 01m73qg9ahqrg3xem61vbz3d4z
  text: |-
    Research (2026-11-10).
    - The ACPClient test resumes on the SAME connection ("first"). So the old owner and the new owner are one connection. An update that the agent records before the take has the route of the old owner with no hold (`recordAndRoute`). On the same connection it goes out live after the request.
    - In `restoreSession` (SessionResume.swift) the hot path comes after `await loadSessionContext(...)` (a hop to the `SettingsStore` actor). The agent actor is free during that await. A live update of the tree that the agent records in that interval goes out with no hold, after the request on the wire, before the replay announces its session. This matches positions 16 (grandchild state_update) and 17 (child state_update, background lists the grandchild): the grandchild had just started (its `workStarted` gives its `running` state, and `subagentActivity` gives the state of the child).
    - The await before the take is old: it is in 89152e3 too (the hot path was put after `loadSessionContext` in d8fa169, ^23KNDP; the hold of d9427c1, ^4273b5t, begins only at the take). The diff 89152e3..4fd6b94 has no change to the record, the route or the hold of live updates: `SessionResumeHold` got only `admit`, and `ElicitationRelay` got the hold for questions (^w3nmwmw). So no commit in that range adds a new path around the hold. The commits in the range change the timing of the start of a sub-agent run (8d7c456 style text at the start of each run, ACPA-20b; 27f8fcc session agent tools, ^b013mv9). That makes the first `state_update` of the new grandchild come later, at the time of the resume of the ACPClient test (it resumes as soon as the grandchild is announced).
    - Plan: a deterministic test on the same connection that holds the resume in `loadSessionContext` (a gated `SecretStore` on a `keychain:` reference of the project config; the merge of the store reads it), lets the child start the grandchild in that interval, and checks the trace with `SubagentWireTraceValidator`. The fix: take the live root before any suspension of the request.
    - Not fixable in the agent: an update that the agent wrote to the wire before it read the request still comes after the request in the trace of the client (frames in flight). The fix makes the window start at the first actor step of the request.
  timestamp: 2026-11-10T21:58:22.289145+00:00
- actor: claude-code
  id: 01m73qw0c15vazt5xe5cvjbg13
  text: |-
    RED and GREEN (2026-11-10).
    - New test `HotResumeTests.aGrandchildThatStartsDuringAHotResumeOnTheSameConnectionWaitsForTheResponse`. Tree: root, child `worker` (has the `agents` tool), grandchild `leaf`. The project config holds `tools.web.apiKeys.tavily: keychain:hot-resume-gate`, and the agent has the new test store `SecretStoreGate` (Tests/.../Support/SecretStoreGate.swift). The test arms the gate and resumes the root on the SAME connection. If the resume reads the configuration before its response, the merge waits in the gate; the test then releases the window hold of the child (the child starts the grandchild), waits until the agent recorded the text of the grandchild, and opens the gate. If the resume does not read the configuration, the response comes first and the child starts the grandchild after it. No clock decides the order. Check: `SubagentWireTraceValidator().validate(trace) == []`.
    - RED on fcd75f1 (before the fix): position 1 rule 3 "an update in <child> before it is announced", position 4 rule 4 "capabilities of <grandchild> before the response", position 6 rule 2 "a state_update of <grandchild> before the response", position 7 rule 2 "a state_update of <child> before the response". The same form as the ACPClient trace.
    - Fix: `restoreSession` checks for a live root before `loadSessionContext`. New `resumeLiveRoot` (SessionResumeHot.swift) does the cwd check with the recording root of the live session (`entry.transcriptDirectory.deletingLastPathComponent()`, the documented `<recording root>/<sessionId>/`), validates the additional roots, and calls `resumeLiveSession`. No `await` comes before the take. New helper `requestedAdditionalRoots(of:)`; `requireRecordedWorkingDirectory` is now internal. The cold path is unchanged in order.
    - GREEN: the new test passes.
    - Dead end: the first run of the test on a scratch worktree of 89152e3 used a clone of the main `.build`; the build failed (module cache path), and `swift test --skip-build` ran the OLD binary of main. That result is not valid. A clean build of 89152e3 runs now.
  timestamp: 2026-11-10T22:04:46.337226+00:00
- actor: claude-code
  id: 01m73r20sd9x58bfq64vw1r3tc
  text: |-
    ### implement — changed
    - cause: in `restoreSession` (Sources/FoundationModelsACPAgent/Agent/SessionResume.swift) the check for a live root came after `try await loadSessionContext(...)`. During that await the agent actor is free, and the take of `resumeLiveSession` (which starts the hold of ^4273b5t) has not come yet. A live update of the tree that the agent records in that interval gets the route of the owner with no hold (`recordAndRoute`). When the connection of the request is the owner (the ACPClient test resumes on the same connection), the update goes out after the request, before the replay announces its session and before the response: rules 3, 2 and 9 of `SubagentWireTraceValidator`.
    - commit that introduced it: d8fa169 (^23KNDP, "hot resume takes over a live session tree"), which put the hot path after `loadSessionContext`. d9427c1 (^4273b5t) added the hold, but only from the take on. Proof: the new test fails on a clean build of 89152e3 (scratch worktree, removed after) with the same violations as on fcd75f1. So no commit in 89152e3..4fd6b94 adds the defect. The commits in that range (for example 8d7c456 ACPA-20b, 27f8fcc ^b013mv9) only change the timing of the start of a sub-agent run, so the first `state_update` of the new grandchild comes into the interval more often. A bisect with a deterministic test cannot find a timing change, so no bisect was run.
    - fix: `restoreSession` checks for a live root before `loadSessionContext` and calls the new `resumeLiveRoot` (SessionResumeHot.swift). It does the cwd check with the recording root of the live session (`entry.transcriptDirectory.deletingLastPathComponent()`), validates the additional roots (new `requestedAdditionalRoots(of:)`), and calls `resumeLiveSession`. No `await` comes between the start of the request and the take. The cold path keeps its order. The rules of ^4273b5t and ^w3nmwmw are unchanged, and their tests in HotResumeTests pass.
    - files: Sources/FoundationModelsACPAgent/Agent/SessionResume.swift, Sources/FoundationModelsACPAgent/Agent/SessionResumeHot.swift, Tests/FoundationModelsACPAgentTests/HotResumeTests.swift (test `aGrandchildThatStartsDuringAHotResumeOnTheSameConnectionWaitsForTheResponse`), Tests/FoundationModelsACPAgentTests/Support/SecretStoreGate.swift (new).
    - evidence: `swift test` exit 0, 1972 tests in 215 suites passed (1 known issue, the existing withKnownIssue), zero compiler warnings.
    - limit: an update that the agent wrote to the wire before it read the request still comes after the request in the trace of a same-connection client (frames in flight). The agent cannot prevent this. The fix closes only the interval inside the agent. If foundationmodelsacpclient-76 still sees rare failures, that is the cause, and the client test or the validator must allow for it.
    - open: acceptance item "foundationmodelsacpclient-76 confirms 10 of 10" needs a commit and a client run.
    - next: /review
  timestamp: 2026-11-10T22:08:03.373302+00:00
- actor: claude-code
  id: 01m73r696hfhds5h8erwfz87tq
  text: |-
    ### review — clean
    - evidence: review sha 934c0b7~1..934c0b7 — 0 findings (0 confirmed, 0 refuted; 7 attempted, 0 failed). 4 files reviewed; 4 .kanban files excluded by .reviewignore.
    - next: the task is in done. The acceptance item for 10 of 10 runs on foundationmodelsacpclient-76 stays open for the client to confirm.
  timestamp: 2026-11-10T22:10:23.057805+00:00
- actor: claude-code
  id: 01m73smyactb84g9xj8j3f87nh
  text: 'Acceptance confirmed by foundationmodelsacpclient-76 (2026-11-10): on ACPAgent d8c0fb1 (Agents 609c812, Skills 1421de4, Multitool 558b503e), 10 of 10 full integration runs passed 28/28. aHotResumeKeepsTheRunningChildRunning 10/10, aKilledAgentResumesTheNestedRunWithItsTree 10/10, anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall 10/10. No failure of the in-transit form. ACPClient closed its task ^tfx3jr2 (board commit ee5812f).'
  timestamp: 2026-11-10T22:35:52.012551+00:00
position_column: done
position_ordinal: ffffd780
title: 'Regression: a hot resume sends the state_update of a child before its announcement (2 of 10 ACPClient runs)'
---
## What
Report of foundationmodelsacpclient-76 (2026-11-10). `aHotResumeKeepsTheRunningChildRunning` failed in 2 of 10 runs on ACPAgent 4fd6b94 (with Agents 609c812, Skills 1421de4). It passed 10 of 10 on ACPAgent 89152e3. Thus a commit between 89152e3 and 4fd6b94 is the probable cause.

Trace of both failures:
- 15 > session/resume <root> request
- 16 < session/update <grandchild> state_update
- 17 < session/update <child> state_update
- 18 < session/update <root> subagent_update(<child>)
- 19 < session/update <child> subagent_update(<grandchild>)
- ... 27 < session/resume response
Violations: position 16, rule 3 (an update in <grandchild> before it is announced) and rule 2 (a state_update before the response is history replayed as current). Position 17, the same for <child>, and rule 9 (background lists <grandchild> before it is announced).
Full traces: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/c6a2f1c1-d86c-4e3e-8e84-1327458d50a2/scratchpad/runs10c/hot-run4.txt and hot-run10.txt (logs run1.log … run10.log in the same folder).

Suspects (commits after 89152e3 that touch the hot resume): ^w3nmwmw 272959f and 6d12624 (questions in the hold, `SessionResumeHold.admit`, `SessionResumeHot.swift`), and possibly ^b013mv9 / ^p21q32s (SessionResume.swift). Find the exact cause first: a live `state_update` of a child must go into the hold (`SessionResumeHold`) during the window, and it must never reach the new connection before the response.

1. Reproduce it with a deterministic test in `HotResumeTests.swift` (no wall clock). Make the child send a `state_update` in the window between the take and the replay of its announcement.
2. Fix the order. Keep each rule of ^4273b5t and ^w3nmwmw.
3. Send the commit to foundationmodelsacpclient-76 for 10 more runs.

## Acceptance Criteria
- [ ] After a hot resume, no `state_update` or other update of a tree session reaches the new connection before its announcement or before the response.
- [ ] foundationmodelsacpclient-76 confirms `aHotResumeKeepsTheRunningChildRunning` passes 10 of 10.

## Tests
- [ ] A deterministic test that fails before the fix and passes after it.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1