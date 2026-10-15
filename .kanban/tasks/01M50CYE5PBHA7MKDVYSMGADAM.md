---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Elicitation task 7: the user presence of a session comes from the client capabilities'
---
Step lead request, elicitation phase 2 (elicitation-plan.md sections 0, 2, 7, 9). Send the design to the step lead first. Needs Extras dbd91de (UserPresence) and Router fa9bf088 (SessionConfiguration.userPresence).

- ACPAgent decides the presence of a session from the client capabilities of `initialize`: no elicitation capability, or neither form nor URL, gives `.headless`; else `.interactive`. It gives the presence to Router as SessionConfiguration.userPresence at session/new and session/resume. The replacement session of a model slot switch keeps the presence.
- A host with no relay wired (no ACP client connection, for example an in-process composition) is also headless, so a question never waits forever.
- The relay: in a headless session no question reaches it. Its behavior for an interactive session does not change.

Tests (fixed order, fail on the old code): an interactive client's session asks and the question reaches the client; a client with no elicitation capability gets cancel with the reason and no elicitation/create. #elicitation-phase-2