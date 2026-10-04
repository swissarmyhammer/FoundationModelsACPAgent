---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m44j4pa5kckgn46rdcckm36s
  text: |-
    Research and reproduction (implement step).

    Reproduction:
    - A loop of 100 separate `swift test --skip-build --no-parallel --filter ProgressReporterTests` runs: 100 pass, 0 SIGPIPE. One process for each run is too slow to hit the window.
    - In-process repetition hits it: `swift test --skip-build --no-parallel --filter <f> --maximum-repetitions 1000 --repeat-until fail`, 10 trials each.
      - Filter `ProgressReporterTests`: 9 SIGPIPE (signal 13), 1 SIGSEGV (signal 11), 0 pass. Stop at repetition 44 to 993.
      - Filter `ProgressReporterTests/theReporterReadsTheProgressOnTheMainActor`: 8 SIGPIPE, 1 SIGSEGV, 1 pass (1000 repetitions).

    Root cause (production code, not only the test):
    - `ProgressReporter.report(on:while:)` starts the poll `Task`, and its `defer` only calls `polling.cancel()`. It never awaits the task. Cancel does not stop a poll that is between its main-actor read and its `report(...)` call, because `poll` checks `Task.isCancelled` only at the top of the loop.
    - Thus a draw can occur after `report(on:)` returns. In the test, the capture is then gone: `Pipe` closes its read end, but the poll task still holds the write `FileHandle` through the Noora pipeline, so the write raises SIGPIPE and ends the test process.
    - The same late draw also runs at the same time as the Noora completion render of `ProgressStep.runInteractive()`. Noora's `Renderer` is not thread safe. The two SIGSEGV crash reports (`~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-10-04-175513.ips` and `-175404.ips`) both stop in `Renderer.render(_:standardPipeline:)` from `ProgressStep.runInteractive()` in `ProgressReporter.report`, in an array release: a data race on the renderer state.
    - In production this also breaks the documented contract "the drawing is over before the first answer chunk can arrive": a stale bar line can come after the completion line.

    Plan: make `report(on:)` cancel and then await the poll task before it returns, on the success path and on the throw path. Thus no draw occurs after the work ends, and the completion render never runs at the same time as a poll draw. A global `signal(SIGPIPE, SIG_IGN)` would hide only the SIGPIPE and not the SIGSEGV or the late draw, so it is not the fix.
  timestamp: 2026-10-04T22:56:48.453002+00:00
- actor: claude-code
  id: 01m44k7w72h763nr7x5zy15688
  text: |-
    Implementation landed.

    Fix (production): `ProgressReporter.report(on:while:)` in `Sources/acp-agent/ProgressReporter.swift` now runs the poll as a child task of `withThrowingTaskGroup`. When the work ends, `defer { group.cancelAll() }` cancels the poll, and the group waits for it before the closure returns. Thus every poll draw ends before Noora draws the completion line and before `report(on:)` returns. The doc comments of the type and of the function now say this.

    Why not `signal(SIGPIPE, SIG_IGN)` or `F_SETNOSIGPIPE` on the capture: those hide only the SIGPIPE symptom in the test. The same late draw also gave SIGSEGV (a data race in Noora's `Renderer` between the poll draw and the completion render), and in production it can draw a stale bar line after the completion line. `TerminalCapture` is not changed, so a late draw can still raise SIGPIPE, and the reproduction loop below is a true check of the fix.

    TDD:
    - New test `ProgressReporterTests.theLastDrawLandsBeforeTheReportReturns`, with a `LateReadProgress` stand-in whose read signals the work to return and then holds the main thread for 0.2 s. RED before the fix: `capture.text()` held only the start line and the completion line, with no "late read". GREEN after the fix (0.207 s).

    Reproduction loop after the fix (same command as before, the new test skipped so the set of tests is the same):
    - Filter `ProgressReporterTests`: 10 of 10 trials pass, 1000 repetitions each, 0 SIGPIPE, 0 SIGSEGV. Before: 9 SIGPIPE, 1 SIGSEGV of 10.
    - Filter `ProgressReporterTests/theReporterReadsTheProgressOnTheMainActor`: 10 of 10 pass, 1000 repetitions each. Before: 8 SIGPIPE, 1 SIGSEGV, 1 pass of 10.

    Gates:
    - `swift build -c release`: complete, 0 warnings from this package.
    - `swift test` (parallel): 740 tests in 83 suites pass (1 known issue, the deliberate `withKnownIssue` in HarnessSmokeTests).
    - `swift test --no-parallel`: 740 tests in 83 suites pass, 59.2 s.
    - `swift build --package-path IntegrationTests --build-tests`: complete, 0 warnings from this package.

    ### implement — changed
    - evidence: 2 files — Sources/acp-agent/ProgressReporter.swift, Tests/FoundationModelsACPAgentTests/ProgressReporterTests.swift; repetition loop 20/20 trials x 1000 pass after (17 SIGPIPE + 2 SIGSEGV of 20 before); swift test 740 pass; swift test --no-parallel 740 pass; release and IntegrationTests builds clean
    - next: review
  timestamp: 2026-10-04T23:16:01.378649+00:00
- actor: claude-code
  id: 01m44kcq9yyabkefgn9s7f6y3n
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a09e736). 0 findings, 0 confirmed, 0 refuted. 7 validator tasks attempted, 0 failed. 2 source files reviewed. The .reviewignore rule excluded 2 .kanban files.
    - next: none. The task moved to done.
  timestamp: 2026-10-04T23:18:40.190605+00:00
- actor: claude-code
  id: 01m44kcxqsvnwvg35cswdqttwj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Sources/acp-agent/ProgressReporter.swift, Tests/.../ProgressReporterTests.swift
    - test: green — swift test 740 passed; --no-parallel 740 passed; repetition loop 20/20 trials x 1000 pass (was 17 SIGPIPE + 2 SIGSEGV of 20)
    - commit: a09e736
    - review: clean — no findings
  timestamp: 2026-10-04T23:18:46.777819+00:00
position_column: done
position_ordinal: ff9a80
title: A serial swift test run can stop on SIGPIPE in ProgressReporterTests.theReporterReadsTheProgressOnTheMainActor
---
## Why

Found during ^00myfrq. One `swift test --no-parallel` run on 2026-10-04 stopped with "swiftpm-testing-helper ... exited with unexpected signal code 13" (SIGPIPE). The last test that started was `ProgressReporterTests.theReporterReadsTheProgressOnTheMainActor()`. The next serial run on the same code was green (739 tests, 53.8 s). The fault is thus intermittent.

## Probable cause (not yet proven)

- `TerminalCapture` holds a `Pipe`. When the capture is released, both pipe ends close. Its doc comment says: "The capture must outlive every draw to its `destination`."
- In `theReporterReadsTheProgressOnTheMainActor()`, the test does not use `capture` after `reporter.report(on:)`. The other tests of the suite read `capture.text()` or `capture.bytes()` at the end, and that keeps the capture alive. Swift can release `capture` after its last use, and then a draw of the renderer writes into a pipe with no read end, which raises SIGPIPE and ends the whole test process.
- A second candidate: a draw after `report(on:)` returns, or a descriptor number reused after `capturingStandardOutput` of the test before it.

## What to do

- Prove the cause first (for example, a loop of `swift test --no-parallel --filter ProgressReporterTests`).
- Keep the capture alive to the end of each test (`withExtendedLifetime(capture)`), or make the write end ignore SIGPIPE (`fcntl(fd, F_SETNOSIGPIPE, 1)`, as `SpawnedACPAgent` does), so a write fails with EPIPE and does not end the process.

## Acceptance

- The cause is proven and removed.
- `swift test --no-parallel` is green.