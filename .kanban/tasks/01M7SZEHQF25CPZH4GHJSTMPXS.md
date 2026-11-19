---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tfk69hfjsnsh4z3ck38ecs
  text: |-
    ### review — clean
    - evidence: review sha 0ad75db~1..0ad75db; 2 files reviewed; 0 findings, 0 confirmed, 0 refuted; 7 review tasks attempted, 0 failed, 0 skipped.
    - next: none. The task is in done.
  timestamp: 2026-11-19T18:02:40.817521+00:00
position_column: done
position_ordinal: ffffffa280
title: 'Flaky under full-suite load: RedriveInterruptedRunsTests.theReplayOpensTheOriginalCallWhenNoHistoryWasWritten'
---
During ^jex3g34 (2026-11-19), one full `swift test --skip-build` run (2502 tests) failed this test one time: `SubagentWireTraceValidator().validate(wire.trace)` gave `backgroundList` at position 20: "background drops <child id> before it finished". The suite alone passed 3 of 3 runs, and the next full run passed (2502 tests, 0 failures). The ^C0991F card also tells of a flake of OrderlyShutdownTests under full load.

Find the order race of the background list of the re-driven child against the end of the child when the history file is gone, and make the test deterministic. #flaky