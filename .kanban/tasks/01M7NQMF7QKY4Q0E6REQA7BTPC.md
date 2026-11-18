---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'ACPA-6: send a session_message update for each delivered directory message'
---
Decision D199 (f) in `TestudoApp/features/decisions.md` (commit 740cd1a), and ACPA-6 in `TestudoApp/features/packages/foundationmodels-acpagent.md:76-84`. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, items 1, 2 and 6.

## Dependency

- FoundationModelsRouter task 01M7NQNGH4YGB2Y1SS0JF3J3V5 (the host event of a delivered directory message). Also the Router header for a user message with a source session. Do not start until the Router change is available.
- FoundationModelsExtras adds `SessionMessage.sourceSession`.

## Event to use

Use the existing event `SessionDirectoryEvent.messageDelivered(SessionMessage)` (FoundationModelsExtras). Extras adds no new directory event. `SessionMessage.to` gives the target session, and `SessionMessage.sourceSession` gives the source session of a user message. Do not use a `messageDelivered(_, to:)` form. (Change from the brief, sent by the TestudoApp session.)

## Current behavior

- `mailDelivered` (`Sources/FoundationModelsACPAgent/Agent/ACPEventTranslator.swift:468-472`) calls `receiveMessage(of:)` (`ACPEventTranslator+Messages.swift:84-86`). `SubagentMessageProjector.receive(key:by:text:)` (`SubagentMessageProjector.swift:455-466`) gives `[]` for a mail that is not registered.
- Only the messages of the `agents` tool and the host mail route (`AgentRunLinks.swift:26-40`, `.mailed(...)`) register a message.
- So the client of the target sees no entry for a message from the `sessions` tool or from the user in another session.

## Change

1. For each `messageDelivered` event whose `SessionMessage.to` is a session of this agent, register the message with the projector. `mailDelivered` then gives one `session_message` update to the client of the target: `messageId`, `senderSessionId` (the sender session, or `sourceSession` for a user message), `recipientSessionId`, and the text as content.
2. Put `SAH.SessionMessage` in `_meta` with `SAH.SessionMessage.inject` (FoundationModelsACP, `SAH/SAHMeta.swift:66-180`; no change there):
   - A message from the user: `sender.kind = user`, with `sessionId`, `title` and `cwd` of the source session.
   - A message from a session: `sender.kind = session`, with `title`, `agent` and `cwd`.
3. Order: the `session_message` update comes before the first chunk of the turn that the message starts. A queued message shows when its turn starts, not when it is queued.
4. The messages of the `agents` tool keep their current updates. Make sure that no message gets two updates.
5. When this lands, tell the TestudoApp session to update the ACPA-6 status and the "(to confirm with the ACP spec)" note of rule 2 of the category document (TestudoApp task ^k6wacyz). Do not write to the TestudoApp board.

## Tests

- A user message with a source session, delivered to an idle hosted session: one `session_message` update with `_meta.sah.message.sender.kind == "user"` and the source session id and title, then the agent chunks.
- A message from a session through the `sessions` tool: `sender.kind == "session"`, with title, agent and cwd.
- A queued message: the update comes when its turn starts, not before.
- A message of the `agents` tool: the same updates as today, no second update. #d199 #at-sessions #acpa-6