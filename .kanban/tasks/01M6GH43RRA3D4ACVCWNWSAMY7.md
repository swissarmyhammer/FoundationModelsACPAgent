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
- actor: claude-code
  id: 01m6hevk0trtnjf3nfb9xscaxk
  text: |-
    DESIGN (step 1, read-only; written by the client session, 2026-11-03). Sources read: Agent/SubagentAnnouncer.swift, ACPEventTranslator.swift (origin/main), the Router SessionEvent API, FoundationModelsAgents AgentRun and the agents tool docs.

    ## 1. Which events show a message between a caller and a child
    Public events only. The Router MailRecord type is internal, so the agent cannot read mail records. The agent reads SessionOutput events.
    - `send agent` (caller to run). It runs as a tool call of the `agents` tool in the CALLER session (op "send agent", arguments id and message). The text of the message is `arguments.message`. AgentRun.deliver mails it to the child session. deliver returns only `.delivered` or `.ended(state)`: it gives NO MailID. The child session sends `.mailDelivered(MailID)` when the model sees the mail. That event has no sender and no body.
    - `send caller` (run to caller). The run posts a message with ToolContext.message. The CALLER session sends `.runMessage(OperationEvent)` when it journals the message: `detail` is the text, `correlationID` is the completionToken of the run, the origin is Origin.mail(MailID) of the caller mail. The translator ignores `.runMessage` today (ACPEventTranslator, case .runMessage). The run itself made the message with a `send caller` tool call, which the child stream shows (toolCall and toolStatus, arguments.message).
    - The final message of a run. The CALLER session sends `.runSettled(OperationEvent)` with the completionToken. VERIFY: the detail of the settled event is the final text (or a pointer to it). The child stream also has the final agent message (text deltas, `.answered`).

    ## 2. GAP to decide (one question)
    For `send agent` the agent cannot join the caller tool call to the child MailID. Options: (a) FoundationModelsAgents: `deliver` returns the MailID (recommended, small, other board). (b) Router: `.mailDelivered` carries the mail (sender and body). (c) Match by order: the n-th caller mail of the child. (c) is fragile and I do not recommend it. Without (a) or (b), implement `send caller` and the final message first, and `send agent` after.

    ## 3. Mapping to session_message (no session_message_chunk needed)
    A message is whole, so each view is one `session_message` with `content` and the ids. `session_message_chunk` stays unused until a send streams. The outer sessionId is the transcript that holds the view. The OUT view is in the sender transcript, the IN view is in the recipient transcript. Each view has its own messageId (unique in its transcript). Link them only with senderMessageId (on the IN view) and recipientMessageId (on the OUT view). Never merge by content.
    Message ids are deterministic (a hash of the completionToken or the MailID and a counter), so a replay gives the same ids.
    - `send caller` and the final message: OUT in the child transcript (outer = child run id; sender = child; recipient = caller; content). IN in the caller transcript (outer = caller id; sender = child; recipient = caller; senderMessageId = the OUT id). Then a patch of the OUT view: recipientMessageId = the IN id.
    - `send agent`: OUT in the caller transcript (outer = caller; sender = caller; recipient = child), made when the `send agent` tool call completes with the delivered outcome. IN in the child transcript (outer = child; sender = caller; recipient = child; senderMessageId = the OUT id), made at the `.mailDelivered(MailID)` of that mail. Then the patch of the OUT view with recipientMessageId.
    - Never make an IN view from an OUT view alone: the IN view needs the receive event (`.runMessage` or `.runSettled` for the caller, `.mailDelivered` for the child). If the run ended before the message (`.ended`), or the mail was cancelled (`.cancelled(MailID)`), the agent sends the OUT view only.
    - The final message: the OUT view carries senderMessageId only when it links an existing child agent message. Keep the link rules of the RFD: link only by ids.
    Session ids: the child run id is the Router session id of the child, and it is the wire session id of the child. The caller is the root session id or the parent run id.

    ## 4. Ordering
    - The announcement (`subagent_update`) comes before the first event of the child, so before each view in the child transcript (already the rule).
    - All views of the final message (OUT in the child transcript, IN in the caller transcript, the OUT patch) come BEFORE the final tool_call_update of the agents call. The client removes the child at that update, and it drops later traffic of that child (an OUT patch or an IN view in the child transcript after it would be lost).
    - OUT before IN for the same message. The patch (recipientMessageId) comes after the IN view.

    ## 5. Replay
    Views are transcript entries, so the replay sends them as history before the response, after the announcement of their transcript owner (the engine keeps session_message entries; SessionMergeEngine transcriptUpdates sends them again). The ids are deterministic, so a replay does not make a second entry. A child with a view in its transcript replays that view under the child id.

    ## 6. The client side (so both match)
    SessionMessageEntry (client main) holds messageId, content, senderSessionId, recipientSessionId, senderMessageId, recipientMessageId, meta. It folds `session_message` upserts by messageId with the patch rules (omitted = unchanged, null clears) and `session_message_chunk` appends one content block. What the agent must match: (a) the entry is in the transcript of the outer sessionId, the client never routes by sender or recipient; (b) the client links two views only by the ids, never by content; (c) an IN view before the OUT patch is fine; (d) a view for a removed child is dropped. Client work to add after this design: SessionModel.messageEntry(withId:) and a counterpart lookup (the other view by senderMessageId and recipientMessageId, through session(withId:)). I do this on my side when you tell me the design is accepted.

    ## 7. Tests (agent)
    SubagentMessageProjectorTests: both directions with the link ids; no early IN view; `send agent` to a run that ended (OUT only); a cancelled mail (OUT only); the final message; the order against the final tool_call_update (all views before it); replay gives the same ids. Add a view scenario to acp-test-agent nested-subagents so the client integration tests and the wire trace validator cover it (ask the ACP session).

    ## 8. Open questions
    1. The MailID join for `send agent` (section 2): (a) recommended.
    2. What the detail of `.runSettled` holds (final text or not).
    3. The format of the deterministic message ids (proposal: "msg-" + hash(completionToken or MailID, direction, counter)).
  timestamp: 2026-11-03T19:40:55.706852+00:00
- actor: claude-code
  id: 01m6hew7xjxrarddh69sjvg1qa
  text: 'FACT for the design (open question 2), read in FoundationModelsAgents Run/AgentRun+FinalMessage.swift: the .runSettled event of a run carries an OperationEvent with kind .completed, correlationID = the completionToken of the run, outcome .succeeded / .failed / .cancelled, and detail = report(of: state): for a finished run ''Agent <name> (<id>) finished.'' followed by the FULL reply of the last answer; for a failed run ''Agent <name> (<id>) failed: <reason>.''; for a cancelled run ''Agent <name> (<id>) was cancelled.''. So the detail is the message that the caller model reads, with a header line. Decision for the mapping: the content of the final-message views is the detail as the caller model gets it (one text block). The stop reason of the child state_update stays the machine-readable outcome. A view for a failed or cancelled run has the same shape (the text is the report). DECISION (coordinator): deliver returns the MailID (Agents change, asked); until then step 2 builds send caller and the final message first, in the worktree wt-msg, after the projection commit is pushed.'
  timestamp: 2026-11-03T19:41:17.106581+00:00
- actor: claude-code
  id: 01m6hg8wzeqhdcch4kyjgvcryj
  text: 'UPDATE: the gap of open question 1 is closed on the Agents side. Agents main 3984a94: AgentRun.deliver(_:from:) now returns AgentRunMessageOutcome.delivered(MailID) or .ended(AgentRunState) (isDelivered, mailID), and AgentEnvironment.CallerMail returns MailID?. So the join for send agent is: the MailID of the deliver result = the MailID of the .mailDelivered(MailID) event of the child session. Step 2 can build send agent too, once the agent package uses the new Agents pin. Order of work stays: send caller and the final message first, then send agent.'
  timestamp: 2026-11-03T20:05:40.462565+00:00
- actor: claude-code
  id: 01m6jagc7hvcp9wksg9xts09w5
  text: |-
    ### implement — stuck
    - reason: The agent cannot see the mail of `send agent`. The join in the design comment (MailID of the deliver result = MailID of the child `.mailDelivered(MailID)`) does not reach the host.
    - checked in the pinned sources (Agents a8597b6, Router, Extras):
      - `AgentsToolOperations.deliver(to:in:)` calls `run.deliver(message, from: sender)` inside the `agents` tool. It keeps the outcome and its MailID inside the tool. It writes only telemetry (`AgentMessageRecord`, no id) and the answer text `AgentsToolText.messageSent(to:)` (no id).
      - `AgentEnvironment` has no hook for a delivered message. `callerMail` gets a MailID only for a caller that is not a run.
      - The child event `SessionEvent.mailDelivered(MailID)` has no sender and no body.
      - `Mail` is public, but the session shows it only in `pendingMessages()`, and only while it waits in the queue. A mail that the pump took is gone. A snapshot at the tool result is a race with an idle child. `MailRecord` and `MailRecordSegment` are internal.
      - `RouterSessionDirectory.message(_:to:)` reads the ledger of `directory.send`. `run.deliver` does not write to the ledger.
    - Match by order of the n-th caller message is rejected in the design (fragile). I did not use it.
    - not blocked: `send caller` and the final message. `.runMessage(OperationEvent)` and `.runSettled(OperationEvent)` on the caller session carry the text, the completion token and the mail origin.
    - no code changed. Nothing is half done.
    - DECISION NEEDED from the user (a change in a sibling package, so I did not make it). Choose one:
      - (A) Agents: `AgentEnvironment` gets an observer for each delivered caller message: run, sender, MailID, text. `AgentRun.deliver` calls it. The agent joins the MailID to the child `.mailDelivered(MailID)`.
      - (B) Router: `SessionEvent.mailDelivered` carries the `Mail` (sender and body), or a new event does. The child stream then has all the data.
      - (C) Both directions through the order match. Not recommended.
    - next: after the decision and the sibling card, run /implement again on this card. Build all four criteria in one pass.

    step: implement
    outcome: stuck
    evidence: no files changed; the MailID of `send agent` is not visible to the host (Agents a8597b6 tool path, Router SessionEvent.mailDelivered)
    task: ^nwsamy7
  timestamp: 2026-11-04T03:44:08.433996+00:00
- actor: claude-code
  id: 01m6jnfgtd6dncxshfk3f1ckea
  text: |-
    ### unblocked by Agents 5e8d090 (peer report)
    - Read the record from SessionEvent.toolCallReport(report): report.attachments with schemaName == "FoundationModelsAgents.AgentMessageSent". report.op is "agents", not "send agent".
    - contentJSON keys: mailId (String, ULID of the mail in the receiver session); direction ("toChild" for send agent, "toCaller" for send caller); receiverRunId (String?, only for toChild; it is the child session id); receiverSessionId (String). There is no message text.
    - A toChild attachment arrives on the CALLER session event stream. A toCaller attachment arrives on the child run stream (runEventObserver).
    - Limit: send caller from a run to a host-session caller makes no mail and no attachment. The host already sees it as a runMessage event.
    - The message text must come from the mail in the receiver session.
    - Run `swift package update` first, because the package resolves Agents from main.
    - Order: finish ^awnkj0k first, then this task.
  timestamp: 2026-11-04T06:55:54.701160+00:00
- actor: claude-code
  id: 01m6kckbtn90ehz74qraa70dnz
  text: |-
    ### implement — changed (branch wt-msg, worktree FoundationModelsACPAgent-wt-msg)
    - The agent sends `session_message` for the messages between a caller and a child. New: SubagentMessageProjector (two views for each message, ids derive from one key, once per key), SentMessageRecord, ACPEventTranslator+Messages. The surface shares one projector through RunCallJoinTable.messages.
    - Text: the receiver session does not give it (mailDelivered has only the id). The text comes from the arguments of the sender tool call (`message`). The SDK toolCall event can come before or after the report; both orders work. The sent-message record is not tool call content any more.
    - send agent: OUT in the caller stream when the record and the text are known. IN in the child stream at the child `mailDelivered`, never before. The link patch (`recipientMessageId`) follows the IN.
    - send caller (call route, live runs): `runMessage` of the caller is both steps. send caller over the mail route (restored run): same as send agent, in the other direction.
    - Final message: OUT in the child stream at the end of the run (before the child last state), with the reply of the run; the IN in the caller stream at `runSettled`, before the settlement and the final status of the agents call, with the report text the caller model gets. The OUT names the IN at once, because the caller can journal the end after the child retired. A failed or cancelled run has an IN only.
    - GAPS: (1) a run that settles inside the settle period has no `runSettled` event (Router withdraws it), so no final-message view for it. (2) A restored run final message comes as plain mail (no attachment), so no view. (3) Two parallel agents calls of one round can swap texts when Router joins the SDK id wrongly (known Router limit). (4) A run that was never announced has no bind, so its run-route views are lost.
    - Tests: SubagentMessageProjectorTests, SubagentMessageTranslationTests, SubagentMessageWireTests (real send agent with the new ScriptedPassStep.toolCallFromFile). Full swift test: 1736 tests, 190 suites, 0 failures, 1 known issue (HarnessSmokeTests). Review has not run (worktree).

    step: implement
    outcome: changed
    evidence: 7 new files, 8 changed files (see the commit on wt-msg)
    task: ^nwsamy7
  timestamp: 2026-11-04T13:39:57.909140+00:00
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: doing
position_ordinal: '8380'
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