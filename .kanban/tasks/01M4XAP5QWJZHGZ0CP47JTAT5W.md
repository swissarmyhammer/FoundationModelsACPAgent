---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xc0qb3s7vzcs61ww1txmms
  text: 'From the T1 acceptance: record in the docs that the log metadata key of session/cancel changed from cancel.result (requested | nothingToCancel) to cancel.signal_id (the SignalID of cancelAll()). A dashboard that reads cancel.result must change.'
  timestamp: 2026-10-14T14:10:47.779016+00:00
- actor: claude-code
  id: 01m4xsv632aarknyh8etxmzj78
  text: 'T7 done. Commit 6d80770 (README: host example waits for connection.closed and the teardown; "a prompt is mail"; session/cancel and /compact are signals; log key cancel.result → cancel.signal_id; acp-print text; stray EvaluationTests/.shell/log deleted, the package was removed in 394a277; .gitignore keeps .shell/ out). bench/README.md: the skill trigger gate measures what the model chose, not when (in 8c7308e). IntegrationTests agree with the API (SessionDrain = awaitIdle(), gated stub, exit events). No DocC catalog exists. Final runs: root 937 pass, 1 known issue; IntegrationTests (live models, all in cache) 26 tests in 12 suites pass in 176 s. Row 4 check met: compactReturnsBeforeItsCompactionEnds and aCompactionWithNoPromptOpenReachesTheClient pass.'
  timestamp: 2026-10-14T18:12:26.338469+00:00
depends_on:
- 01M4XAP084YKF2WYZQ221KSVA4
position_column: done
position_ordinal: ffd480
title: 'T7: IntegrationTests, EvaluationTests, Examples, bench and docs agree with the new API; final run and report'
---
Step 4 of the mail work, part T7. Do this task after T6.

Work:
- Make IntegrationTests, EvaluationTests, Examples, bench and the docs (DocC, README) agree with the new API.
- IntegrationTests and EvaluationTests must build.
- Run their live tests one time, only if the models are in the local cache.
- Then do one full suite run and the final commit.
- Send the final report to the step lead: the list of commits and the check of mailbox.md section 8 row 4.
- Do not push until the step lead accepts step 4.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4 #docs