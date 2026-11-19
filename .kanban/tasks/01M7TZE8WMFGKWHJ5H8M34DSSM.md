---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7v2r52zw8jymb2wke2qwpjy
  text: |-
    ### review — clean
    - evidence: `review sha 7c6fed5~1..7c6fed5`; 1 file reviewed, 0 not reviewed; findings 0, confirmed 0, refuted 0; 7 validators attempted, 0 failed, 0 skipped.
    - next: none. The card is in done. The CI run of main must be green after the push.
  timestamp: 2026-11-19T23:37:26.367320+00:00
position_column: done
position_ordinal: ffffffae80
title: 'CI: TranscriptSearchHostReadTests time out waiting for the turns of a prompt in the change stream'
---
CI failure on main 2606f6e (2026-11-19), run 44606074514 (`gh run view 44606074514 --log-failed`). Not caused by the Multitool break.

## What happened

- `TranscriptSearchHostReadTests.theAgentGivesTheTurnsOfAPromptInTheChangeStream()` and `theComposedAgentGivesTheTurnsOfAPromptInTheChangeStream()` (from ^twh8ceh) went past their 180 s time limit (`TranscriptSearchHostReadTests.swift:113`, `:127`), with `Expectation failed: Self.holdThePrompt(turns, of: session)` (`:122`, `:136`). The turns of the prompt never came on the change stream.
- The CI script also reported `swift test still running after N minutes; sampled and killed its test processes` (a hang); the samples are in the log.
- 2646 tests, 5 issues including 1 known issue.

## Likely cause (verify; do not guess)

The change stream emits only after the index update queue applies the change. The queue worker runs at `.utility` priority; ^6yqbvx6 raised it only inside `waitUntilApplied()`. These tests wait on the stream with no `waitUntilApplied()`, so on a slow CI runner the worker can be held back past the limit. Another possibility: the subscriber subscribes after the change was emitted (the stream gives only later changes), so the test waits for a change that already went.

## Work

1. Read the CI log and its stack samples. Reproduce under load locally (loop the suite with `--parallel` and other suites).
2. Fix the cause. If it is the subscribe-after-emit order, subscribe before the prompt. If it is the priority, wait with `waitUntilApplied()` before the stream read in the test (the shutdown path already does), or make the stream test read `turns(of:)` after the wait. Keep the test meaning: the host gets the turns through the public API.
3. Do not raise the time limit to hide it.

## Tests

- The two tests pass in a loop under load (`--parallel` with other suites) with zero failures.
- After the push, the CI run of main is green. #bug #ci #search #flaky