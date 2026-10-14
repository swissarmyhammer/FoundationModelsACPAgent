---
assignees:
- claude-code
depends_on:
- 01M4XANGGXCAEBEPNBWHE1RMW6
position_column: todo
position_ordinal: '8480'
title: 'T4: Signals and commands (cancel, /compact, CompactionReporter)'
---
Step 4 of the mail work, part T4. Do this task after T3. Refer to mailbox.md section 8 row 4 and the signals table.

Work:
- session/cancel uses cancelAll(). It ends with idle and the stop reason cancelled (an ACP rule).
- /compact only sends the compact signal and returns at once.
- CompactionReporter uses the SignalID of the compaction as the one id. Remove makeCompactionId, reportStart and reportEnd. The report comes from the compaction events.
- RunCallJoinTable.recordAgentRunEvent, CommandDispatch and RoutedSelectionModel follow the new API. respond(to:) is a helper and stays.

Check of row 4: /compact returns at once, and its report comes from the events. The events of a compaction are not lost when no prompt is open.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4