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