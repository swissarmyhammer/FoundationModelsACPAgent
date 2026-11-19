---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rzxjvsqtjhy6782n9wjf8v
  text: |-
    Research and design (2026-11-18):
    - The ACP id of the user message of a model prompt is the text of its MailID. The incoming view of a message from another session has the id `in-<mail id>`. An action command echo has a UUID id and sends no mail.
    - The Router sends `mailDelivered` for each mail of a batch one after the other, before any other event of the answer (also for mail that joins a running answer). `answered`/`answerFailed` ends the answer. The public `SessionEvent` stream gives all of this; `MailRecord` and `ForkCutHistory` of the Router stay internal, so the agent does not read the journal.
    - Design: the projector records history-only updates `_mail_delivered {mail, batch, answer}` and `_answer_ended {answer}` (`MailDeliveryRecord`, `MailDeliveryTrack`) through a new `recordDelivery` closure (no client gets them; the replay filters them). `ForkSourceHistory` counts one turn for each delivered record whose mail matches a user message or an incoming view, in record order; the turn start is the first record of its batch; the running answer start is the first record of the last answer with no end record (only when the state runs). The ACP copy moves a delivered user message to its record, and keeps an undelivered user message (action echo, cancelled queued prompt) at its place.
    - A history file now has `recordsMailDelivery: true`. A file of an earlier build gets synthetic records at read (each ULID user message and each incoming view is one batch and one answer).
    - Discovery: the Router sends a streamed prompt alone ("A stream goes alone"), so two queued ACP prompts never batch. Directory messages do batch, so the batch tests send two directory messages while turn 3 holds.
    - Discovery: the Router keeps back the text of an answer that only run mail started, so the run-result tests wait for an inline signal tool, not for the text.
    - The directory message view is sent during the translation of `mailDelivered`, so the delivered record goes BEFORE the translation, and the end record after it.
  timestamp: 2026-11-19T04:09:29.721120+00:00
- actor: claude-code
  id: 01m7s003wxc8t7vsb2ee417d9e
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsACPAgent/Agent/MailDeliveryRecord.swift; changed SessionForkHistory.swift, SessionFork.swift, SessionHistory.swift, SessionProjector.swift, SessionBuild.swift, DirectoryMessage.swift and SubagentMessageProjector.swift (they use `MessageId.incomingView(of:)`), README.md, ARCHITECTURE.md; tests SessionForkTests.swift (sample histories carry delivery records; new: anActionCommandIsNoTurn, aQueuedPromptTakesTheIndexOfItsDelivery, aCutOnTheSecondMessageOfABatchCopiesNoMessageOfTheBatch, noCutWhileARunResultRunsKeepsTheLastCompletedTurn, aHistoryFileOfAnEarlierBuildCountsEachUserMessage) and SessionForkHandlerTests.swift (real Router directory: anActionCommandBetweenTwoPromptsIsNoTurnOfTheFork, aCutOnTheSecondMessageOfABatchCopiesTheRouterFork, aCutOnTheSecondMessageOfABatchKeepsNoMessageOfTheBatch, noCutWhileARunResultRunsForksTheLastCompletedTurn, noCutWhileARunResultRunsCopiesTheRouterFork; the last two of the four compare the ACP copy with the Router journal of the fork). Each new test failed first, except the earlier-build file test, which guards the old count through the change.
    - test: `swift build --build-tests` Build complete!, 0 compiler warnings; `timeout 1800 swift test --skip-build`: 2435 tests in 255 suites pass, 1 known issue (the pre-existing `withKnownIssue` in HarnessSmokeTests).
    - No Router change was needed. Not committed.
    - next: review.
  timestamp: 2026-11-19T04:10:52.701921+00:00
depends_on:
- 01M7QV7TASP791JZFKKEMD9F4N
position_column: doing
position_ordinal: '8180'
title: 'D205: the fork turn count of the agent agrees with the Router (action commands, queued prompts, batches, a running answer)'
---
Found during ^emd9f4n (2026-11-18). Decision D205. The agreed rule (see the comments of ^emd9f4n): one turn for each DELIVERED mail whose body is `.userMessage` or `.agentMessage`, from any route, in delivery order, from the source's own journal. The agent copies the retained ACP history of the source up to the cut, and the Router copies its journal up to the same cut. When the two counts disagree, the client of the fork shows a history that is not the history that the fork model has.

## Cases where the counts can disagree today

1. **Action commands.** A command such as `/compact` or `/help` echoes a user message in the ACP history but delivers no mail. The agent counts it as a turn; the Router does not. Change: count only a user message whose prompt was delivered as a mail. Mark the echo of an action command in the retained history (or keep the mail id of each delivered prompt), so that the map can tell them apart, also after a resume from disk.
2. **Queued prompts.** A prompt that the client sends while the session is busy is echoed when the agent accepts it, not when the Router delivers it. Thus the ACP order can differ from the delivery order. Change: count in delivery order (for example, by the `mailDelivered` event of each prompt), not in echo order.
3. **Batches.** One Router prompt can deliver two or more waiting messages together. The Router rounds a cut inside a batch to the batch edge. The agent copies the ACP history without the same rounding, so the ACP copy can differ by the batched messages. Change: the agent knows the batch from the delivery events; round the ACP copy to the same batch edge.
4. **No cut on a running answer.** The agent uses the last state in its history (running or requires_action) and cuts before the last turn. When the running answer is for a background-run result (not a turn), the Router keeps the last completed turn, and the ACP copy drops it. Change: use the same rule as the Router: `.lastCompletedTurn` never goes past the start of the running answer, and a running answer that is not a turn does not remove the last completed turn.

## Tests

- An action command between two prompts: a cut after the second prompt gives the same turns in the ACP copy and in the Router fork.
- A prompt queued while busy: the index follows the delivery order.
- A cut on the second message of a batch: the ACP copy has the same messages as the Router fork.
- No cut while a background-run result runs: the fork has the last completed turn in both.
- A check that compares, for a fork, the user and agent messages of the ACP copy with those of the Router journal of the fork. #d205 #fork