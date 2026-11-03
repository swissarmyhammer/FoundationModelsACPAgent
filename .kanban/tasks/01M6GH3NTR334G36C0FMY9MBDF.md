---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gjcsgbjy21b89nnw04b9gd
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:30.699546+00:00
- actor: wballard
  id: 01m6gjn11ysapdmmbtcpdby6ab
  text: 'CORRECTION (from the Router session review): the relayed ElicitationRequest does NOT name the asking child session. `askedBy` is a tool name; `agentPath` (agent names) and `source` (tool name) are public but not session ids. Do not try to read the child from the relayed question. NEW APPROACH: when the Router card (01M6GJJKPTESHZGW7N2AAY83G3, accessor `RouterSessionDirectory.session(id:)`) is done, attach a projector to the child session itself. The original elicitationRequested then arrives on the feed of the child under the child session id, and the answer goes with `child.respond(elicitationId:response:)`. This is the same code as for the root. RISK TO CHECK: the parent session also gets a relayed copy of the question with the same elicitationId. The root projector must not send it a second time when a child projector asks it already (dedupe by elicitationId). Add a test for exactly-one request on the wire. Until the Router card is done: the child has no session, the question reaches the user under the root id, and this task is blocked for the child-id rule.'
  timestamp: 2026-11-03T11:28:00.574381+00:00
- actor: wballard
  id: 01m6gy2ys4c6as08fky9kaqppp
  text: |-
    ROUTER FINDING (accessor card, 2026-11-03): an answer given through the CHILD session does NOT end the parent copy of the relayed question. The parent copy stays open until the relay ends (the child closes), and then it ends once as cancel ("run cancelled"). If both levels answer, the child keeps the first answer.
    RULES FOR THIS TASK:
    1. The root projector must NOT send a relayed elicitation (ElicitationRequest.isRelayed) to the client at all when a child projector is attached for that child. The client gets exactly one request: the child one, under the child session id. So the client never sees an already-answered question.
    2. A relayed copy must not count for the state of the root (the ledger): do not report requires_action for the root because of the relayed copy alone. The child state is reported under the child id.
    3. When the child closes, the Router ends the parent copy as cancel. Do not forward that cancel to the client (the client never saw the copy).
    4. A follow-up Router card (low priority, after the six) fixes the relay so an answer at the child ends the parent copy. Until it is done, rules 1 to 3 hold.
    Add tests: the relayed copy is never sent; the root state is not requires_action from the copy; the end-of-relay cancel is not forwarded.
  timestamp: 2026-11-03T14:47:51.332005+00:00
depends_on:
- 01M6GH30709S58BK3AQ1VMBAM7
position_column: todo
position_ordinal: '8480'
title: Ask a child elicitation under the child session id and answer it through the child session
---
## What
RFD rule: an agent-to-client request for a child carries the child session id and stays attributed to it. In this package the ONLY agent-to-client request that exists is the elicitation (checked by grep: no `requestPermission`, `createTerminal`, `readTextFile`, `writeTextFile` call; `SandboxConfig` has no permissions section; `TerminalStream` only projects display terminal updates). So this task covers elicitation only. If a permission, file or terminal request is added later, it follows the same rule in its own task.

Today `SubagentQuestionRelay` (FoundationModelsRouter) asks the question again in the parent session, and `ElicitationRelay` (`Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift`) sends it under the root id. The relayed `ElicitationRequest` does NOT name the asking child (`askedBy` is a tool name; `agentPath` is a list of agent names; `source` is a tool name).

Approach (from the Router session review): when the Router card `01M6GJJKPTESHZGW7N2AAY83G3` (public accessor `RouterSessionDirectory.session(id:)`) is done, attach a projector to the child session itself. The original `elicitationRequested` then arrives on the feed of the child under the child session id, and the answer goes with `child.respond(elicitationId:response:)`. The root projector must NOT send the relayed copy again (dedupe by `elicitationId`): the client must get exactly one request. Replay never reissues an elicitation. A cancel of the work answers its pending request `cancelled`.

BLOCKED BY (other board): Router accessor card `01M6GJJKPTESHZGW7N2AAY83G3`. Until it is done the child has no session here, and the question reaches the user under the root id (accepted for now; do not build the child-id rule before the card is done). Do not change the Router.

## Acceptance Criteria
- [ ] An elicitation from a child run arrives at the client once, with the child `sessionId`.
- [ ] The answer reaches the asking child run.
- [ ] The relayed copy in the root stream is not sent a second time.
- [ ] A cancel of the child answers its pending elicitation `cancelled`.
- [ ] Replay sends no elicitation.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ChildElicitationTests.swift`: child id, exactly-one request, answer path, cancel, no replay.
- [ ] Run `swift test --filter ChildElicitationTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.