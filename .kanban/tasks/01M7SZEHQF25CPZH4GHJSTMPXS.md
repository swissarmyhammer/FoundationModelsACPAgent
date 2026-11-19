---
assignees:
- claude-code
position_column: todo
position_ordinal: '9280'
title: 'Flaky under full-suite load: RedriveInterruptedRunsTests.theReplayOpensTheOriginalCallWhenNoHistoryWasWritten'
---
During ^jex3g34 (2026-11-19), one full `swift test --skip-build` run (2502 tests) failed this test one time: `SubagentWireTraceValidator().validate(wire.trace)` gave `backgroundList` at position 20: "background drops <child id> before it finished". The suite alone passed 3 of 3 runs, and the next full run passed (2502 tests, 0 failures). The ^C0991F card also tells of a flake of OrderlyShutdownTests under full load.

Find the order race of the background list of the re-driven child against the end of the child when the history file is gone, and make the test deterministic. #flaky