---
assignees:
- claude-code
depends_on:
- 01M4XANBPVKDGSA84BZ9XS24PN
position_column: todo
position_ordinal: '8380'
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