---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: 'Flake: ChildSessionProjectionTests.aChainOfThreeSessionsFollowsTheSameRuleAtEachLink sees the leaf final text in the child under load'
---
## What
`ChildSessionProjectionTests.aChainOfThreeSessionsFollowsTheSameRuleAtEachLink` failed once at `ChildSessionProjectionTests.swift:487` in a unit run of merged main (the quit pause, the re-drive and the hot resume were merged). The expectation that the child's text does not contain `LEAF-FINAL-TEXT` failed. The output was self-contradictory (the inner `contains` printed `false`, the negated expression `true`). It passed in the next full run and alone. Every test in the failing suites took about 45 seconds in that run, so the machine was stalled (load). The same run also had the flake of ^gwvht3e (`OrderlyShutdownTests.aShutdownEndsThePromptOfTheRootAsInterrupted`).

## Do
1. Find the race by reading the code, not by repeat runs. Check the timing between the leaf's updates and the final status of the `agents` call, how the test reads the child's stream (a snapshot taken before the stream has settled), and whether a recent change (the shutdown pause `SessionShutdownPause`, `InterruptedToolCalls`, the open-call replay, the hold on a final status in `SessionResumeOpenCalls`) can let the leaf text reach the child stream at a different time.
2. Decide: a test that does not wait for its precondition (wait on a condition, never on a sleep), or a product race (fix the product and pin it with a deterministic unit test).
3. Do not skip or weaken the test; no retry. Unit tests only; do not run integration tests.

## Acceptance Criteria
- [ ] The cause is named on the card.
- [ ] The test waits for its precondition, or the product race is fixed and pinned by a unit test.
- [ ] Touched suites pass.

## Workflow
- Use `/tdd`. #subagents