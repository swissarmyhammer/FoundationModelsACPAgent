---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6gh7aremewz4a5wdxbarz9z
  text: 'BLOCKER (outside this board): the wire cases `SessionUpdate.sessionMessage` and `sessionMessageChunk` do not exist in FoundationModelsACP. No card exists yet; the user must decide first how to add them. Do not start until the user gives a decision.'
  timestamp: 2026-11-03T11:03:03.182308+00:00
- actor: wballard
  id: 01m6gj6bm3972e5r5jsx07var9
  text: 'UPDATE of the blocker: the card now exists on the FoundationModelsACP board (id 01M6GJ664BHY454C5NFPFCSP79). The vendored unstable schema already defines subagent_update, session_message and session_message_chunk; the card adds them to the generated Swift SessionUpdate. This task starts after that card is done.'
  timestamp: 2026-11-03T11:19:59.875201+00:00
- actor: wballard
  id: 01m6gjcsw84pc1efwwxz1029e9
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:31.080449+00:00
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: todo
position_ordinal: '8780'
title: Send session_message for the messages between a caller and a child
---
## What
The `agents` tool has `send agent` (caller to run) and `send caller` (run to caller). Show these messages on the wire as `session_message` and `session_message_chunk` (RFD), not as tool call content.

- Fields: `messageId` (unique in its transcript), `senderSessionId`, `recipientSessionId`, `senderMessageId`, `recipientMessageId`, `content`.
- The outer `sessionId` names the transcript. The outgoing view is in the sender transcript and the incoming view is in the recipient transcript. Each view has its own `messageId`; link them only with `senderMessageId` and `recipientMessageId`.
- Never make an incoming entry from an outgoing one alone.
- Source: the mail records of the child session and of the parent session (Router `MailRecordSegment`), seen through the run event observer in `Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift`. Write a `SubagentMessageProjector` in `Sources/FoundationModelsACPAgent/Agent/`.

## Acceptance Criteria
- [ ] `send agent` makes an outgoing `session_message` in the parent transcript and an incoming one in the child transcript after the child received it.
- [ ] `send caller` makes the same in the other direction.
- [ ] The final message of a run is a `session_message` to the caller.
- [ ] No incoming message appears before the child received it.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SubagentMessageProjectorTests.swift`: both directions, link ids, no early incoming entry.
- [ ] Run `swift test --filter SubagentMessageProjectorTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents