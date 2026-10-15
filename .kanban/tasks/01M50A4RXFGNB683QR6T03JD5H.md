---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Defect: a pause of mail delivery is not visible to the client, and the headless run reports done'
---
Found by the Router review of mailOnlyAnswerLimit. Do not start before the step lead says so.

Problem:
- When Router pauses mail delivery (SessionEvent.mailDeliveryPaused), ACPEventTranslator (ACPEventTranslator.swift:382-386) sends nothing on the wire. The client sees idle with no notice.
- The headless `acp-agent run` stops at the first idle after its own echo and reports done. Router still holds the paused mail, so the held results are lost.

Work:
- Make the pause visible to the client: an agent message, or a `_`-prefixed state or meta field. Send the design to the step lead first.
- The headless run must not report done while Router holds mail. It reports the pause and ends with a clear failure (an error exit code and a message on stderr).

Tests: fixed-order tests that fail on the old code: the pause reaches the client; the headless run ends with the failure and not with done when the delivery is paused. #defect #elicitation-phase-3