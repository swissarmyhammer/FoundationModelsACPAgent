---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kzvm3g0x9gs38m2ev0k1ab
  text: 'A second full root run on the same tree (no code change) passed: 886 tests in 97 suites, 1 known issue (the harness self-test), exit 0. Thus the hang is intermittent: 1 of 2 full parallel runs on 2026-10-10.'
  timestamp: 2026-10-10T22:45:07.824561+00:00
position_column: todo
position_ordinal: '9480'
title: AgentsToolTests.closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses can hang in the full parallel run
---
## Problem

In the full root suite run of 2026-10-10 (task ^b2kb6j1), the test `closingASessionStopsItsAgentRunsBeforeTheRootSessionCloses()` in `Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift` hit its time limit: `Time limit was exceeded: 60.000 seconds`, failed after 64.030 seconds. The other 885 tests passed.

The same test, run alone (`swift test --filter AgentsToolTests`), passes after 0.950 seconds.

The change of ^b2kb6j1 does not change the path of this test: the process has no `XDG_CONFIG_HOME`, no `AGENTS_DEFAULTS_DIR` and no `SKILLS_DEFAULTS_DIR`, thus the `agents` and `skills` stacks of the stub agent have the same layers as before.

## Possible cause (not proved)

The test starts a slow agent run, then closes the session. `session/close` stops the agent runs before the root session closes. Under a high load, the run can be cancelled before its first submission starts. If the runner then waits for a run that never closes its session, the root session never closes, and the event stream of the test never ends.

## What to do

- Make the hang reproducible (for example, a load on the machine, or many runs of the test in parallel).
- Find the cause, and correct it in the agent or in FoundationModelsAgents.
- Keep the test without a clock limit as the proof.

## Acceptance

- [ ] The cause is recorded, and the test passes in each full parallel run. #tests