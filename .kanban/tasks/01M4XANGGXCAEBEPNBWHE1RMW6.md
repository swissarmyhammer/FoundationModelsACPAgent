---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xb6vqm686z1d5xbs02e7st
  text: |-
    Decisions from T0 (step lead).
    G2: rule A. The headless CLI (RunPrompt, acp-print) waits for the first idle after the echo of its own messageId. An idle means that no work is left, so its own prompt ended too. No _meta extension.
    G3: first make the error impossible. Check that the session is open before the session/prompt response is sent (a closed session gives an error before insertion; ACP permits this). A new MailID cannot be a duplicate. If mail(_:) still throws after the response (a close in the window), the projector sends the error text as an agent message, then idle with an error stop reason. Add a fixed-order test for that window.
  timestamp: 2026-10-14T13:56:40.308965+00:00
- actor: claude-code
  id: 01m4xc5mc8x6qjvt34cw3dddp2
  text: 'From the T2 decisions (step lead, Q4): T2 already puts the prompt in with mail(_:) and an agent-made MailID. T3 does the rest: the MailID as the ACP messageId, the fixed order of task 49, the removal of the two busySession gates, and the headless CLI rule A. With no busy gate, more than one prompt can be open: the projector sends running when the first prompt opens and idle when the last open prompt ends (Q2: no state update while no prompt is open).'
  timestamp: 2026-10-14T14:13:28.584934+00:00
- actor: claude-code
  id: 01m4xe3d1njb9yzjd7qbhjt7m1
  text: |-
    From the T2 acceptance (step lead check): SessionProjector.stop() cancelled each reader, also the reader of a closed session, so a last update could be lost if a cancelled AsyncStream drops its buffer. Fix in this task: stop(after closed:) reads the closed sources to their natural end and cancels only the others. Callers: teardown, RoutedPrompt (awaitIdle, close, stop), the synthetic drivers.

    T3 design:
    - The prompt MailID is made in acceptPrompt; the response messageId is its description; insertUserMessage uses that id.
    - Fixed order (task 49), all in the after-response hooks: response, user_message echo, (session_info_update of the first activity), running, then the mail.
    - More than one prompt can be open: the projector keeps a table of open prompts. A stream message goes alone in its submission, so an event holds the MailID of at most one prompt.
    - Session state: running when the first prompt opens, idle when the last open prompt ends (with its stop reason). No state update while no prompt is open (Q2).
    - session/cancel and close mark each open prompt.
    - No busySession gate in acceptPrompt and SessionResume.
    - Headless CLI (RunPrompt, acp-print): waits for the first idle after the echo of its own messageId (rule A).
    - G3: the closed check before the response stays; a fixed-order test for a refused mail after the response.
  timestamp: 2026-10-14T14:47:12.693797+00:00
- actor: claude-code
  id: 01m4xedqwf2ev1jcp9fxjsf3v3
  text: 'Decision (the user, through the step lead): proposal A. With the busy gate of session/resume removed, a resume of a live session first does the full teardown of the entry, as session/close does: cancelAll(), the open prompts end with idle and stop reason cancelled, the relay cancels its client requests, the Router session closes, and the projector stops (stop(after:) for the closed session). Then the restore runs as today. There is never more than one projector for each session. Fixed-order test: a resume while a prompt is open; the old prompt ends cancelled, no update of the old session comes after the restore starts, and the new projector serves the session.'
  timestamp: 2026-10-14T14:52:51.471365+00:00
- actor: claude-code
  id: 01m4xf1shzhntzj19qx7fd45z6
  text: |-
    T3 done. Commit 214b873. Full suite (Router 6cb38629, Extras d0d4653): 935 tests pass, 1 known issue (not new), no warnings. Runs: 2 (the first run had 8 issues: old expectations against decided rules, below).

    Changed tests (decided rules, no test deleted):
    - awaitingUserPairsRequiresActionWithRunning and awaitingUserReturnsToRunningWhenTheBodyThrows now start the prompt first (Q2: requires_action only while a prompt is open).
    - aBusySessionRefusesASecondPromptAsAClientError became aSecondPromptDuringARunningPromptIsAcceptedAndWaits (task 3: no busy gate).

    New tests: awaitingUserSendsNothingWhileNoPromptIsOpen, theSessionGoesIdleWhenTheLastOpenPromptEnds, theMessageIdOfAPromptIsItsMailId, aMailThatTheSessionRefusesAfterTheResponseEndsThePromptWithTheError (G3 window), aResumeWhileAPromptIsOpenEndsThatPromptCancelledFirst (decision A), PromptEndTrackerTests (3 tests, rule A).

    Differences from the plan:
    - running is now sent by the prompt itself before its mail (task 49), not at the first submissionStarted; the projector call stays and does nothing a second time.
    - With more than one open prompt, only the last prompt to end sends an idle (its stop reason). The stop reason of an earlier prompt goes only to its telemetry.
    - A cancel that comes before the mail of a prompt ends that prompt cancelled with no mail (cancelAll cannot reach mail that is not queued).
    - session/resume of a live session with no prompt now also closes the old Router session (before, it stayed open).
    - The command sink of the projector now waits until each update went out, so an .action command's text comes before its idle.
  timestamp: 2026-10-14T15:03:48.543575+00:00
depends_on:
- 01M4XANBPVKDGSA84BZ9XS24PN
position_column: done
position_ordinal: ffce80
title: 'T3: Prompts are mail'
---
Step 4 of the mail work, part T3. Do this task after T2. Refer to elicitation-plan.md tasks 3, 49 and 43.

Work:
- session/prompt puts the prompt with the synchronous mail(_:). It answers with the MailID as the ACP messageId. If the ACP messageId format does not accept the MailID, ask the step lead.
- Keep the fixed order of task 49: the response, the user_message echo, running, then the mail.
- Remove the two busySession gates.
- The headless CLI (RunPrompt, acp-print) waits for the terminal of its own MailID, not for the first idle.
- Wait on an id only after mail(_:) returned it.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4