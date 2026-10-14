---
assignees:
- claude-code
depends_on:
- 01M4XAN04THNK0TRFW6JJPXVYH
position_column: todo
position_ordinal: '8180'
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