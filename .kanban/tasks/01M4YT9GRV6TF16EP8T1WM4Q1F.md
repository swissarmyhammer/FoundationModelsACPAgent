---
assignees:
- claude-code
position_column: done
position_ordinal: ffda80
title: The relay's own declines carry their reason (.decline(reason:))
---
Step lead request, before E2.

Today the relay declines with a plain .decline when the client does not support the mode, when the request has no payload of its mode, or when a URL elicitation id is a duplicate. The reason goes only to the log. Extras ElicitationResponse now has .decline(reason:), and Router shows the reason in the prompt text.

Work: send .decline(reason:) with the reason that goes to the log today, so the tool and the model see why. Update the doc comments that say the response has no reason field.

Tests: one test for each decline reason (unsupported mode, missing payload, duplicate URL id): the response that reaches Router carries the reason.

Check: one full run, commit, push when green. #elicitation-phase-1