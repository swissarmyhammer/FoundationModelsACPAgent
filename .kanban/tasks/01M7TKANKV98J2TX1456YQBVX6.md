---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tyc3xjc8zq86441mp16mf6
  text: |-
    ### review — clean
    - evidence: review sha f9b97ce~1..f9b97ce: 0 findings, 0 confirmed, 0 refuted. The engine did 7 review tasks. 0 tasks failed and 0 were skipped. It reviewed 2 files.
    - next: none. The task is in done.
  timestamp: 2026-11-19T22:20:57.650892+00:00
position_column: done
position_ordinal: ffffffaa80
title: ScheduledAgentEndToEndTests is flaky under a parallel load
---
Found during ^8qsp7hb (2026-11-19, main after 5b71964).

Evidence:
- A full `swift test --skip-build` gave two time limit failures (60 seconds): `aScheduleSurvivesAShutdownAndAColdResumeAndFires` and `aRestoredFiringHoldsTheResumedRootOutOfTheNoWorkState`. The next full run with the same build passed.
- `swift test --skip-build --filter "ScheduledAgentEndToEndTests|AgentTranscriptSearcherTests|TranscriptSearch" --maximum-repetitions 10` gave one issue in `aCancelOfTheRootKeepsTheScheduleAndItFires`: "the wait for the result message of the firing was cancelled before the condition came". This test does no shutdown.
- `--filter ScheduledAgentEndToEndTests` alone passed.

A comment on the task 01M7CX2YPXBGCW47ZGPYBPC6AP says that the shutdown variant hung past the time limit when the tests ran in parallel, and that nobody examined it.

Change: find the cause with evidence (a loop with `--maximum-repetitions`, under a parallel load), and fix the cause. Do not raise the time limit.

#test #flaky