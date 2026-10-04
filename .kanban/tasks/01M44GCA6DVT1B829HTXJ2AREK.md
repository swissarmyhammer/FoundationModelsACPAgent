---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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