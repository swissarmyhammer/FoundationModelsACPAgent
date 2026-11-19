---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
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