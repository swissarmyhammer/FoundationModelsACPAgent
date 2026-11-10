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
position_column: todo
position_ordinal: 8d80
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