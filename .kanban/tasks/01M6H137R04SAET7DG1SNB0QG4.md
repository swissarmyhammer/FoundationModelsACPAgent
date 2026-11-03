---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6h14bs1sh4kkt4jr37m2cy2
  text: |-
    DECISION (coordinator, 2026-11-03): follow the ACP v2 spec. The prompt lifecycle page says: "While foreground work is blocked on user action, the Agent SHOULD report requires_action. Once reported, it MUST report running when foreground progress resumes." So a question that waits for the user (a non-relayed elicitation of this session) makes the session state requires_action, and the answer or end of the question makes it running again (or idle, if the work ended). This replaces the old design note that the agent never sends requires_action; update that comment in ElicitationRelay.swift and the tests that assert it. The resume snapshot and the live changes must agree. A relayed copy of a child question sends nothing (see the ROUTER FINDING comment on the attribution task). A child session reports its own requires_action under its own id; the root does not report requires_action for a question of a child (the parent snapshot lists the running child in its background list instead).
    This is a behavior change that clients see (a StateBanner for requires_action while a question waits). Say it in the task comment and in the commit message.
  timestamp: 2026-11-03T15:41:03.137486+00:00
- actor: claude-code
  id: 01m6h2k68ahc6smqek9rp0sphb
  text: |-
    implement: changed. Live requires_action transitions are in, done together with the review fixes of ^ag9ve1x. Root swift test: 1343 tests, 147 suites, all passed (1 known issue that was there before).

    Behavior change that clients see: while a non-relayed question of the session waits for the user, the agent sends requires_action (a client can show a StateBanner). When the question ends, it sends running (work goes on) or idle. This follows the ACP v2 prompt lifecycle and the coordinator decision on this card. The old design note "the agent never sends requires_action" is replaced in ElicitationRelay.swift, PromptState.swift and README.md. Put this in the commit message.

    Implementation. SessionStateLedger has userWaitStarted(_:) and userWaitEnded(_:resumedWork:since:), and computes the state: requires_action, else running when busy, else idle. It sends only a real change. The relay calls them around each non-relayed question (a copy of a child question has an agentPath, so it sends nothing). The wait ends after the answer went to Router. An answer that Router took resumes a run, and the ledger keeps the session busy until the next work event (workEventMark). So no idle goes out between the answer and the work. A URL-mode accept keeps requires_action until the flow completes.

    Consequence to know: an open question of a background run, after its prompt ended, keeps the session in requires_action. The idle (with the stop reason of the prompt) goes out when that question ends. PromptFollowUpTests changed for this (anOpenQuestionReportsRequiresActionUntilItEnds).

    Tests: Tests/FoundationModelsACPAgentTests/RequiresActionStateTests.swift (ledger transitions, answer that resumes work, work that already ended, a real question reaching the client, a relayed copy sends nothing). ElicitationRelayTests (form, URL, cancel) and PromptFollowUpTests assert the new sequence.
  timestamp: 2026-11-03T16:06:37.578242+00:00
position_column: review
position_ordinal: '8280'
title: Live state updates send requires_action while a question waits for the user, and leave it when the question ends
---
## What
The resume sync card can send a requires_action snapshot when a question of the session waits for the user. The live path did not: SessionStateLedger sent only running and idle. So after a requires_action snapshot, no live change told the client that the question ended.

Done: the relay tells the ledger at the start and the end of each non-relayed question. The ledger computes the state (requires_action, running, idle) and sends only a real change. A relayed copy does not count (agentPath is not empty). The docs that said the agent never sends requires_action are updated. Decision (coordinator): follow ACP v2, so a waiting question is requires_action.

## Acceptance Criteria
- [x] A question that waits for the user sends requires_action; its answer or end sends running or idle as the session state is.
- [x] A relayed copy sends nothing.
- [x] The resume snapshot and the live changes agree.

## Tests
- [x] Tests in Tests/FoundationModelsACPAgentTests for the ledger and the relay (RequiresActionStateTests.swift, ElicitationRelayTests.swift, PromptFollowUpTests.swift). Tag: #subagents

Status: in review.
