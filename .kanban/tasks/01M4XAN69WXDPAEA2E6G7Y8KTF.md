---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xbztvz57t8mbkbvwkwypj3
  text: |-
    T1 done. Commit 56c8363. Full suite: 924 tests pass, 1 known issue (not new), no new warnings. The first run had 24 issues; both causes are fixed (below), then one more full run.

    Differences from the plan, with reasons:
    1. The log record of session/cancel had the key cancel.result (requested | nothingToCancel). cancelAll() gives no result, only a SignalID. The key is now cancel.signal_id with the SignalID. A dashboard that reads cancel.result must change.
    2. /compact in T1 still waits: it sends the signal and waits with awaitTerminal(of:). This keeps the behavior until T4.
    3. Extra breaks from the newer ACPClient (not Router): ConnectionModel.openSessions is now an array, and SessionModel.sessionId is nonisolated. Test support and 4 tests are changed.
    4. An elicitation answer is now mail that starts one more answer (mailbox.md section 5). The scripted model plays the same script on each pass, so 4 elicitation tests ran the eliciting call again with no end (251 declines). New helper ScriptedPromptFixture.makeToolPromptScript(code:onPromptContaining:) plays the call only on the caller prompt. Behavior change for a client: after an elicitation, the model makes one more answer.
    5. TranscriptStore.transcript(for:) now also gives the .mail records of Router. The contract (all recorded events of the session) is correct; the two tests now compare the conversation kinds and check that the mail records belong to the session.
    6. IntegrationTests (SessionDrain uses drain()) is not changed in T1; it is part of T7.
  timestamp: 2026-10-14T14:10:18.623507+00:00
depends_on:
- 01M4XAN04THNK0TRFW6JJPXVYH
position_column: done
position_ordinal: ffcb80
title: 'T1: Port ACPAgent to the new Router and Agents API'
---
Step 4 of the mail work, part T1. The API port. Do this task after T0.

Work:
- streamSessionEvents() gives SessionOutput (the event and its origin). Change each consumer.
- The type of RoutedSession is `any RoutedSession`.
- Change session.cancel() to cancelAll().
- Change messageIds to mailIds.
- compact() returns a SignalID at once. Change each consumer.
- Agents: RunEventObserver gets SessionOutput. deliver(_:from: MailSender) throws. Change each consumer.
- The test double CloseCountingRoutedSession implements the new protocol requirements: mail(_:), cancel(id), cancelAll(), replace, awaitTerminal(of:), awaitAnswer(of:) and the other requirements.

Refer to ../mailbox.md sections 3 to 5. The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4