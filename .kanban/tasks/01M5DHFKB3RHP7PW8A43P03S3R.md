---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: 'telemetry: one span covers the work of a session from the prompt to no-work, so a mail wake is in the same trace'
---
## The gap (telemetry-16, django__django-13447)

`FoundationModelsACPAgent.prompt` ends when `session/prompt` returns: 20:08:41 to 20:16:20 (459 s, `end_turn`). But the work of the session goes on. The coder agent run (`FoundationModelsAgents.run`, 1035 s) ends at 20:33:19. Then the root session wakes on the agent's mail: `FoundationModelsRouter.submission` (cause `mail`, id 4, 38 s, 20:33:19 to 20:33:57). That submission is a root span in a new trace (`ff8c93…`), with no parent and no link. So the last 17 minutes of the instance are not under the prompt, and the wake on mail cannot be joined to the run that sent the mail.

The headless exit comes from the no-work state of the session, not from the end of a turn (see the work registry). The telemetry must follow the same rule.

## The change

- A span for the work of a session (for example `FoundationModelsACPAgent.session.work`). It starts with the prompt and ends when the session reports no work (the idle `_meta.noWork` event). It is the parent context of each submission that starts while it is open, a submission on mail included.
- Keep `FoundationModelsACPAgent.prompt` as it is: it measures the ACP call.

## Done when

- A failing test first (TDD): a prompt that returns before a child run ends, then a mail wake. Today the wake submission is a root span. After the fix it is in the trace of the work span, and the work span ends at no-work.
- In a bench telemetry file, each `FoundationModelsRouter.submission` of an instance has a parent.

If the parent cannot cross the Router mail boundary from here, ask the Router session for a span link from a `mail` submission to the span that sent the mail. #telemetry