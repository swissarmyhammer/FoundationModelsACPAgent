---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tma8fhrkgt7ge5v1kyhcv6
  text: |-
    ### result — no reproduce, closed (2026-11-19)
    - Evidence: the only copy of par-22.log is /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPAgent/7f79398c-4f24-456b-834d-3e154f4ed223/scratchpad/runs/par-22.log. It is exactly 172032 bytes (42 x 4096) and ends in the middle of a line ("Test theRestoredGrandchildRunsAgain() passed after 14.8"), with no test issue. The times of the ^jstmpxs loop show that run 22 was still active more than 6 minutes after its last line, and that the next run started about 600 s after run 22 started. Thus the run probably HUNG and `timeout 600` stopped it; it probably did not crash.
    - No crash report: ~/Library/Logs/DiagnosticReports/ has no .ips file for FoundationModelsACPAgentPackageTests, swiftpm-testing-helper or xctest, on any date.
    - New loop on main f382d51: 100 runs of `timeout 600 swift test --skip-build --parallel --filter 'Redrive|Resume|Restored|Subagent'`: pass=100 fail=0, 0 timeouts, 0 truncated logs, 22-52 s each. A watchdog that samples a run after 240 s never fired. Logs: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPAgent/7f79398c-4f24-456b-834d-3e154f4ed223/scratchpad/hwruns/ (par-summary.txt).
    - The hang was before the ^jstmpxs fix (97903c2), which removed one ordering race of a restored run; it was not proved to be the same cause.
    - No code change. If a parallel resume run hangs again, open a new card with a stack sample of the hung process.
  timestamp: 2026-11-19T19:25:11.025829+00:00
position_column: done
position_ordinal: ffffffa880
title: A parallel run of the resume suites stopped once in the middle of its log, with no test issue
---
Found during ^jstmpxs (2026-11-19).

## What happened

In a loop of 30 runs of the Resume, Redrive, Restored and Subagent suites with `swift test --skip-build --parallel`, one run (log `par-22.log` in the ^jstmpxs worktree scratch folder) stopped in the middle of writing its log. No test reported an issue. It looks like a crash of the test process, not a test failure. The other 29 runs passed. This happened before the ^jstmpxs fix, and it is not the ^jstmpxs flake.

## Work

1. Find the log (the ^jstmpxs worktree was /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/.claude/worktrees/agent-a314d5fceb94b177a; its scratch folder holds `par-22.log`) and any crash report in `~/Library/Logs/DiagnosticReports/` from 2026-11-19 for the test bundle `FoundationModelsACPAgentPackageTests` or `swiftpm-testing-helper`.
2. Run the same parallel loop again (many times, with `timeout`) to reproduce.
3. If it reproduces, find the cause (a crash, an assertion, a deadlock that the time limit killed) and fix it. If it does not reproduce in 100 runs and no crash report exists, record that and close the card.

## Tests

- The loop of the parallel resume suites passes with zero stops in at least 100 runs. #flaky