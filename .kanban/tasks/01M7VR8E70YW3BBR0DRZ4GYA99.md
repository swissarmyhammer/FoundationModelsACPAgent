---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7vrpmd1xwyhvm261m5mwn70
  text: |-
    ### review — clean
    - evidence: `review sha fd62082~1..fd62082` (HEAD~1..HEAD); 1 file reviewed; 0 findings (0 confirmed, 0 refuted). The card has no earlier review findings. The 3 items of the "Change" section are task items, not review findings. They are not checked on the card.
    - next: Make sure that the CI integration job is green after the push. The implementer must set the task items that are complete to checked.
  timestamp: 2026-11-20T06:01:05.185745+00:00
position_column: done
position_ordinal: ffffffb380
title: 'CI: the integration test still expects doctor to exit 1 for an unknown profile; ^sc4qx6z made it a warning (exit 5)'
---
CI run 44656716753 (head f120f89): the job "Integration (opt-in, real dependencies)" failed. `CLIProcessTests.anUnknownProfileMakesDoctorExitOneWithTheFailureOnStderr()` in `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/CLIProcessTests.swift:127` expects exit code 1 (`errorExitCode`). The run gave 5 (`AgentExitCode.doctorWarnings`). Commit 3f24079 (^sc4qx6z) made an unknown profile name a warning with the fallback profile, and it did not update this test. The root `swift test` does not run the integration package, so the unit job did not see it. The product is correct; the test is out of date.

## Change
- [x] The test expects the doctor warnings exit code (5) and the warning on stderr, and nothing on stdout. Change its name and its doc comment to match. Commit 9413d77.
- [x] `swift test --package-path IntegrationTests --filter CLIProcessTests` passes. 7 tests in 1 suite passed, after `swift package --package-path IntegrationTests update` (the local ACP pin of the nested package had no ACPImport).
- [x] The CI integration job is green after the push. #ci #bug