---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xb6zxnes1gbc5bmqs1x18w
  text: |-
    Decisions from T0 (step lead).
    G4: on cancelAll() and on close, the elicitation relay cancels its own open client requests. A cancel of one run is not covered (gap task on the board).
    G5: the projector gets the typed error of a failed answer with awaitAnswer(of:) inline, when it reads answerFailed. The terminal is already in the ledger, so the call returns at once and the order stays.
    G6 (T4): session/cancel ends with idle + cancelled when the projector reads signalDone of the cancelAll SignalID. If a compaction runs, this comes after the compaction ends.
  timestamp: 2026-10-14T13:56:44.597708+00:00
- actor: claude-code
  id: 01m4xc5j3pb6v1c15k0zc0rsdz
  text: |-
    T2 design accepted (step lead). Design: one SessionProjector actor for each ACP session (start at session/new, resume and load; stop at teardown). It owns ACPEventTranslator (renamed EventProjection), the ElicitationRelay, the history sink and the CompactionReporter. One reader of streamSessionEvents() translates each output in order. drive, followSession, SessionFollowUp and SessionEventBuffer are removed. RunCallJoinTable opens and closes with the projector. An open prompt is a record (MailID, PromptStateOwner, telemetry end). The prompt counters count only events whose origin holds the MailID of the prompt. Stop reason from the terminal of the MailID; awaitAnswer(of:) inline for the typed error. The relay runs each round trip in its own task. The stall guard ends the prompt with _stalled and does not cancel the work (no change).

    Answers:
    Q1: A. A prompt ends at the terminal event of its own MailID. Later background work goes to the client with no prompt open (reverses ^64pav2a, elicitation-plan section 8). Change PromptFollowUpTests to the new order. Add a fixed-order test: a run mail answer after the idle of the prompt reaches the client.
    Q2: No running or idle update while no prompt is open, until Router task 10. requires_action only while a prompt is open.
    Q3: The projector also reads the replacement session of a model slot switch. The reader of the old session stays until that session closes, and its end does not stop the projector. A prompt open on the old session ends at the terminal of its MailID on the old session. Add a fixed-order test for a model slot switch while a prompt is open.
    Q4: The prompt goes in with mail(_:) and an agent-made MailID in T2. The busy gate and the echo messageId stay until T3.
  timestamp: 2026-10-14T14:13:26.262931+00:00
- actor: claude-code
  id: 01m4xdqmy84fbts3pt0nebvvbn
  text: |-
    T2 done. Commit dd26bb5. Full suite on Router fc5acc3b / Extras e454d7c: 927 tests pass, 1 known issue (not new), no warnings. Runs: 2 (the first run had 10 issues from 3 causes, all fixed, below).

    Causes in the first run:
    1. Defect (fixed): the relay now lives for the whole session and kept the connection strongly; the connection keeps the agent, so the agent and the Router session were not released after a close (AgentReleaseTests, ConnectionCloseTests). The relay now keeps the connection weakly, as the history sink does.
    2. Decision Q1 (expected): 3 tests asserted the old ^64pav2a behavior (no idle while a background run waits; a cancelled idle at close for a mail answer). Changed: aSessionInAToolBodyHoldsNoModel and aSessionInAnElicitationHoldsNoModel accept at most one end_turn idle of session A (the question of A stays open); closeEndsAMailStartedAnswerThatWaitsForTheModelQueue expects the end_turn idle of B (the close sends no second idle).

    Differences from the plan:
    - Part of T4 is in T2: /compact no longer sends its own compaction entry (reportStart/reportEnd with makeCompactionId). The projector now sees the compaction events with no prompt open, so the old report made a second entry. /compact still waits for its terminal (T4 makes it return at once and removes the unused functions).
    - Running is still sent at the first submissionStarted of the prompt mail (no change); T3 sets the fixed order of task 49.
    - A refused mail(_:) after the response already ends the prompt with the error text and an error idle (decision G3); T3 adds the open check before the response and the fixed-order test.
    - New test drivers: SyntheticExecution (a projector over a synthetic source) keeps the old call forms of makeSinkedExecution, SyntheticPrompt, RoutedPrompt and LiveShellSession. RoutedPrompt now waits with awaitIdle() after the prompt end, so it still reads the updates of the background work.
    - New tests: aRunMailAnswerAfterTheIdleOfThePromptReachesTheClient, aPromptEndsAtTheAnswerOfItsOwnMailWhileItsRunWaits, theWorkAfterThePromptGoesOutAfterItsIdle, theStopReasonComesFromTheAnswerOfThePromptMail, anEventOfAnotherMailDoesNotCountForThePrompt, aFailedAnswerOfThePromptMailEndsWithTheErrorStopReason, aSourceThatEndsWithThePromptOpenEndsThePromptCancelled, aSlotSwitchWhileAPromptIsOpenEndsThatPromptOnTheReplacedSession, aCompactionWithNoPromptOpenReachesTheClient.

    Check of this task: events with no prompt open reach the client: run mail answer (aRunMailAnswerAfterTheIdleOfThePromptReachesTheClient) and compaction (aCompactionWithNoPromptOpenReachesTheClient).

    After the commit: moved to Router 6cb38629 and Extras d0d4653 (step lead request).
  timestamp: 2026-10-14T14:40:47.560247+00:00
depends_on:
- 01M4XAN69WXDPAEA2E6G7Y8KTF
position_column: done
position_ordinal: ffcd80
title: 'T2: One projector for the whole session lifetime'
---
Step 4 of the mail work, part T2. Do this task after T1. Refer to elicitation-plan.md tasks 1, 4 and 5, and mailbox.md section 3 item 4.

Work:
- Use one reader of streamSessionEvents() for each session, from open to close.
- Rename EventProjection to ACPEventTranslator (mailbox.md section 7).
- Merge drive, followSession and SessionEventBuffer into the projector.
- The stop reason and the end of the prompt telemetry come from the answer events of the MailID of the prompt.
- Slash commands send their updates through the projector.
- The elicitation relay stays for the whole session. It does not stop the projection.

Check of this task: events that come when no prompt is open (run mail, a compaction) get to the client.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4