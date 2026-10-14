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
depends_on:
- 01M4XAN69WXDPAEA2E6G7Y8KTF
position_column: todo
position_ordinal: '8280'
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