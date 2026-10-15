---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Elicitation task 6: acp-agent run and acp-print sessions are headless'
---
Step lead request, elicitation phase 2 (elicitation-plan.md sections 0, 2, 7, 9). Send the design to the step lead first.

`acp-agent run` (RunPrompt.swift) and `acp-print` have no UI, so they advertise no elicitation capability. They give their own ClientCapabilities with no elicitation, with no change to ACPClient (ACPClient task 28 makes it an explicit client setting later). Their sessions are then headless (task 7 rule), so Extras answers each question at once with cancel and the reason RunPlane.noUserPresentReason.

Test: `acp-agent run` with a tool that asks ends normally with the cancel result, and does not hang. Fixed order, fails on the old code. #elicitation-phase-2