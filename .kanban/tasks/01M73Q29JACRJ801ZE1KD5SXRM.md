---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73q2ng3tf3j7geazm18a261
  text: 'Priority: top, directly after ^1et93gh (testudoapp-75, 2026-11-10). More suspects: ACPA-20b 8d7c456 (the start of a restored run), and ^yjj4mr5 23deba2 changes only tests. Bisect between 89152e3 and 4fd6b94 if the cause is not clear from the code, with the deterministic test as the check.'
  timestamp: 2026-11-10T21:50:56.003143+00:00
position_column: todo
position_ordinal: '9180'
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