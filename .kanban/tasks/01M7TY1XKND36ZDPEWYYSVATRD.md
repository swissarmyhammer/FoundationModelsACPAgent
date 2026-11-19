---
assignees:
- claude-code
position_column: todo
position_ordinal: '9980'
title: BlockingFIFO.openWriteEnd(at:) can wait for ever for a reader, and nothing cancels it
---
Found during ^6yqbvx6 (2026-11-19).

## What happened

In a full parallel run under load, one test process hung until the loop killed it. Its stack sample shows a thread blocked for ever in `BlockingFIFO.openWriteEnd(at:)` (`Tests/FoundationModelsACPAgentTestSupport/BlockingFIFO.swift`). The open of the write end of a FIFO blocks until a reader opens the read end. When the reader never comes (for example, the test that should read stopped, failed, or was cancelled), the writer waits for ever, and nothing cancels it. The process then never ends, and the test run hangs until an outer time limit kills it. Old test processes can stay on the machine after that (four orphaned test helpers of this repo were found, about 5 hours old, and were stopped).

## Change

1. Find each caller of `BlockingFIFO.openWriteEnd(at:)` and what reader it expects.
2. Make the open bounded and cancellable: for example open with `O_NONBLOCK` in a loop with a time limit and a check for task cancellation (an open of the write end with `O_NONBLOCK` fails with `ENXIO` while no reader is there), or open the read end in the same helper first so the write open cannot block, or run the blocking open on a thread that a cancel can stop by opening the read end itself.
3. A failed or timed-out open throws a clear error, so the test fails and the process ends.

## Tests

- A write-end open with no reader ends with a clear error within the time limit.
- A cancel of the task that waits ends the wait.
- The normal case (a reader comes) still works. #test #flaky