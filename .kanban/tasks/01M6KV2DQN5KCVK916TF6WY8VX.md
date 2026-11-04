---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6kvk9wqtgr1rhc9sb62n6hs
  text: |-
    ### implement — changed
    - cause: the run helper of ChildSessionProjectionTests used the REAL run clock. Under load the leaf passed the real settle period of the child's start-agent call, so the call went to the background and the leaf's final message came to the child as mail. The scripted playbook matches onPrompt markers on the mail prompt, which holds the earlier prompts (it contains the leaf marker), so the scripted child played the leaf's text in its own stream. The self-contradictory output is a display artifact of Swift Testing; the collected text was "CHILD-FINAL-TEXTLEAF-FINAL-TEXT" (snapshot is a value, no two-moment read exists). Not a product race.
    - proof: RED = one run of a test that held the leaf and advanced a ManualRunClock past the settle period: child text was exactly that string. Fix: run helper now uses a ManualRunClock that never advances. New test aSlowLeafKeepsItsTextOutOfTheChildWhileItsCallIsInline holds the leaf until the calls wait on the clock, then releases.
    - GREEN: ChildSessionProjectionTests suite, 13 tests passed, no warnings from the tests.
    - commit on wt-flake2: see the step return block.
    - files: Tests/FoundationModelsACPAgentTests/ChildSessionProjectionTests.swift
  timestamp: 2026-11-04T18:02:04.567305+00:00
- actor: claude-code
  id: 01m6kw7g6106ajg6bss2yxcg4c
  text: |-
    ### review — clean
    - evidence: review sha e74c776~1..e74c776, 0 findings, 7 rules attempted, 0 failed, 0 skipped
    - next: none. The task moved to done.
  timestamp: 2026-11-04T18:13:06.369851+00:00
position_column: done
position_ordinal: ffffb280
title: 'Flake: ChildSessionProjectionTests.aChainOfThreeSessionsFollowsTheSameRuleAtEachLink sees the leaf final text in the child under load'
---
## What
`ChildSessionProjectionTests.aChainOfThreeSessionsFollowsTheSameRuleAtEachLink` failed once at `ChildSessionProjectionTests.swift:487` in a unit run of merged main (the quit pause, the re-drive and the hot resume were merged). The expectation that the child's text does not contain `LEAF-FINAL-TEXT` failed. The output was self-contradictory (the inner `contains` printed `false`, the negated expression `true`). It passed in the next full run and alone. Every test in the failing suites took about 45 seconds in that run, so the machine was stalled (load). The same run also had the flake of ^gwvht3e (`OrderlyShutdownTests.aShutdownEndsThePromptOfTheRootAsInterrupted`).

## Do
1. Find the race by reading the code, not by repeat runs. Check the timing between the leaf's updates and the final status of the `agents` call, how the test reads the child's stream (a snapshot taken before the stream has settled), and whether a recent change (the shutdown pause `SessionShutdownPause`, `InterruptedToolCalls`, the open-call replay, the hold on a final status in `SessionResumeOpenCalls`) can let the leaf text reach the child stream at a different time.
2. Decide: a test that does not wait for its precondition (wait on a condition, never on a sleep), or a product race (fix the product and pin it with a deterministic unit test).
3. Do not skip or weaken the test; no retry. Unit tests only; do not run integration tests.

## Acceptance Criteria
- [x] The cause is named on the card.
- [x] The test waits for its precondition, or the product race is fixed and pinned by a unit test.
- [x] Touched suites pass.

## Workflow
- Use `/tdd`. #subagents