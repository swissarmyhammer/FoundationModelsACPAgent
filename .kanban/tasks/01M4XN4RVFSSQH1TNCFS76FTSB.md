---
assignees:
- claude-code
position_column: done
position_ordinal: ffd180
title: 'T6: two waits of part 1 did not wait for the fact that their test checks'
---
Found in the root full run after T6 part 1 (scratchpad t18.log), fixed in the T6 final commit. #mail-step-4

1. CompactionReportTests.manualCompactSendsInProgressThenCompletedWithTheSummary waited for the terminal compaction entry, then read the usage_update that the reporter sends after that entry. The 20 ms poll of before hid the gap. Fix: the wait is for a usage_update after the completed entry.

2. SessionLifecycleTests.afterCloseNoSpawnedStdioServerProcessRemains: the kqueue exit event comes at the exit, but pgrep still lists the process until its parent reaps it (a zombie). The final pgrep check failed, and the "gone" read after the arm could miss a zombie and hang. Fix: ProcessExitWatch.hasExited(_:) (kill ESRCH, or pbi_status SZOMB); the final check accepts only processes that exited.