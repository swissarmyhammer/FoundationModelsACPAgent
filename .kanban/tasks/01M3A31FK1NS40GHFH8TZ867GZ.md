---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a38kkrpdtkeqgna2exrczd
  text: 'Review 2026-09-24 (two added items). (1) Multitool: `TurnBoundaryTool.turnWillBegin` comes from FoundationModelsMultitool, and this repository follows Multitool `main`. The Router rename also renames it in Multitool. Do not start before the Multitool change is on Multitool `main`. Run `swift package update FoundationModelsRouter FoundationModelsMultitool`. (2) Router design card 01M3A1F89ZRFMCGTNPBNJDP02P (mail and compaction at each pass): read its result before you start. If `turnWillBegin` (new name) moves to each pass, update `MCPCompositionTests.swift:463` and `:483` to the new count. If `.compaction` can come in the middle of a request, add a test in `EventProjectionTests.swift`: a compaction between two attempts sends its compaction update, and the usage sum and the one `usage_update` stay correct. If that card is not decided, write a comment here and do not wait for it.'
  timestamp: 2026-09-24T16:16:32.888074+00:00
- actor: claude-code
  id: 01m3a3p0rw2wzhcazfthhmgn0r
  text: 'Decision (user, 2026-09-24): the Router agent works only in the Router, so this task owns all changes in this repository for the rename. A comment on Router card 01M3A1F0KE9P9QPEVHXF33Q8GW tells the Router agent not to edit this repository. The Coordination section of this task is thus settled.'
  timestamp: 2026-09-24T16:23:52.348157+00:00
- actor: claude-code
  id: 01m3pmak5ase9w61fny84j4sbt
  text: 'Information from the swissarmyhammer-05 session (2026-09-29): FoundationModelsRouter origin/main f497700 has the Router OTel work A to F, has green CI, and builds with the current Extras (which has the public ModelRef). Router 2a79f92 was red on origin: do not pin to it. When this task moves the Router pin, f497700 or later is a candidate. That also unblocks the Extras pin for ^kfqvqqb and the other OTel tasks. The user has not decided the order of this work yet.'
  timestamp: 2026-09-29T13:05:36.938480+00:00
- actor: claude-code
  id: 01m3q415e6rvq6k4c24r92b8pc
  text: 'Research 2026-09-29. Commit 4ac665b did most of this card. The rg check found 6 stale doc comment lines only (5 in EventProjection.swift, 1 in PromptTurn.swift). It found no code symbol. The Router contract (Session/SessionEvent.swift): an overflow retry sends two submissionStarted/submissionEnded pairs and a `.compaction` between them. Each submissionEnded carries the usage of its own submission only. `generationCall` carries the usage of one generation call, and submissionEnded already sums these. `answered(SessionAnswer)` comes after the last submissionEnded, and its `usage` is the TOTAL of the chain. So the answered usage must never go into the sum. EventProjection already ignores `answered` and `generationCall`, and TurnStateOwner.turnDidStart has a `didStart` guard, so one prompt sends one `running`. The earlier retry test used a NaN context fill and asserted NO usage_update, so it did not prove the sum. The Router design card for each pass (01M3A1F89ZRFMCGTNPBNJDP02P) is settled on main: MCPCompositionTests uses submissionWillBegin, and the build and tests pass.'
  timestamp: 2026-09-29T17:40:05.190853+00:00
- actor: claude-code
  id: 01m3q41aq6mkmh2hzbqg0j6fzy
  text: 'Implementation. (1) PromptTurnTests: the retry test now has the name aRetryWithTwoSubmissionsSendsOneRunningOneSummedUsageUpdateAndOneIdle. It drives the real contract: two submissions (the second with the cause `continuation`), a generationCall for each, and one `answered` event with the chain total. It asserts one running, one usage_update with the sum, and one idle. (2) EventProjectionTests: the new test anOverflowRetrySendsItsCompactionUpdateAndOneSummedUsageUpdate drives submission, compaction, continuation submission and answered. It asserts the compaction meter, one summed usage_update and one running. The shared fold result is now the helper makeFoldResult(). (3) ProjectionTestSupport: makeSubmissionStarted(cause:) has a default of `.message`. SessionAnswer.makeSynthetic(usage:) is new. (4) The stale doc comments now name submissionStarted and submissionEnded. The `answered` arm in EventProjection.project now has a comment that says why its total is not added. The name submissionUsageIsSummedIntoOneUsageUpdate was already correct, so no rename was necessary. RED proof: I added a temporary double count (the answered usage added to the sum). Both new tests failed on the sum assertion. Then I removed it. The production behaviour did not change.'
  timestamp: 2026-09-29T17:40:10.598181+00:00
- actor: claude-code
  id: 01m3q41e654tsdw8bd6jtasjr0
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` passed with zero compiler warnings. The one build line is the SwiftPM note "missing creator for mutated node" for the mlx-swift_Cmlx bundle. It is not a compiler warning, and it is not from this change. `swift test`: 614 tests in 70 suites passed (613 before, plus 1 new). The 1 known issue is the withKnownIssue that HarnessSmokeTests already had. The rg check of the six obsolete names gives no result. Files: Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift, Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift.
    - next: /review
  timestamp: 2026-09-29T17:40:14.149766+00:00
- actor: claude-code
  id: 01m3q4r0wpqcsyhxcn8c6ykw2d
  text: |-
    ### review — clean
    - evidence: review sha HEAD~2..HEAD (93e0b5b, 4c95738). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 6 files reviewed. 4 .kanban files not reviewed because of .reviewignore. No earlier review findings are on the task.
    - next: None. The task is in done.
  timestamp: 2026-09-29T17:52:34.198740+00:00
- actor: claude-code
  id: 01m3q4r8hjgns1hc81b2ra7ge3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files (EventProjection.swift, PromptTurn.swift, EventProjectionTests.swift, PromptTurnTests.swift, Support/ProjectionTestSupport.swift)
    - test: green — swift test 614 tests pass after a fix in SessionResume.swift (release the replaced session before the new code context opens); IntegrationTests build ok
    - commit: 93e0b5b, 4c95738
    - review: clean — zero findings; task moved to done
  timestamp: 2026-09-29T17:52:42.034899+00:00
depends_on:
- 01M3A30KQBCN1051EVS6KCTS5V
- 01M3A30WN7D2CB2X7EGM0K2VN6
position_column: done
position_ordinal: f380
title: Adopt the Router submission events and the submission cancel API
---
## Why

The Router removed its "turn" level. The Router on `main` does not use the names "request" and "attempt" that this card first used. It uses **submissions**. A submission is one SDK call of the chain that answers the messages of a session. A chain can have more than one submission: an overflow retry, a rejected tool call or a compaction continuation starts a new submission with the cause `continuation`.

The Router contract (read in `.build/checkouts/FoundationModelsRouter`, `Session/SessionEvent.swift`, on 2026-09-29):
- `SessionEvent.submissionQueued(SubmissionID)`: the submission waits in the model queue.
- `SessionEvent.submissionStarted(SubmissionStart)`: the submission starts. One for each submission that starts.
- `SessionEvent.submissionEnded(SubmissionEnd{submissionId, usage: TokenUsage?, finishReason})`: one for each submission. It carries the usage of THAT submission only. An overflow retry sends two of these.
- `SessionEvent.generationCall(GenerationCallUsage)`: the usage of one generation call alone. `submissionEnded` already sums these.
- `SessionEvent.answered(SessionAnswer)`: one for each final answer, after the last `submissionEnded`. `SessionAnswer.usage` is the TOTAL of the chain.
- `SessionEvent.compaction(CompactionResult)`: an overflow retry sends one between its two submissions.
- `RoutedSession.cancel() -> CancellationResult` (`.requested` / `.nothingToCancel`).
- Multitool: `TurnBoundaryTool.turnWillBegin()` became `submissionWillBegin()`.

Commit 4ac665b ("refactor(router): adopt the Router generation queue with no turns") did most of this card.

## What

1. Use the Router on `main` (commit 4ac665b).
2. `EventProjection.project(_:)`: map `submissionStarted` to `turnState.turnDidStart()`. `turnDidStart()` sends `running` one time only for each prompt. Sum the usage of each `submissionEnded`. `lastFinishReason` comes from the last `submissionEnded`. Do not add the usage of `generationCall` or of `answered`, because `submissionEnded` already counts those tokens.
3. Use `RoutedSession.cancel()` and `CancellationResult` in `PromptTurn.swift` and `SessionLifecycle.swift`, and the log text `cancel ->`.
4. Update the tests to the submission names. Do not change what a test asserts, except where the event contract changed.
5. Keep the ACP words: `end_turn` (`StopReason.endTurn`), `max_turn_requests`, "prompt turn" in the ACP sense.
6. Do not rename the agent's own "turn" types (`TurnState`, `PromptTurn`, `ScriptedTurnFixture`). Cards ^f9513f2 and ^mdf7fr do that. Prose and plan.md are for card ^wqe0awe.

## Acceptance Criteria

- [x] `swift build` and `swift build --build-tests` pass with the Router on `main`.
- [x] A prompt with a retry (two submissions) sends one `running`, one summed `usage_update`, and one `idle`.
- [x] The usage of each submission is counted one time only. The `answered` total and the `generationCall` usage add no second count.
- [x] `rg -n "turnStarted|turnEnded|cancelCurrentTurn|turnWillBegin|noTurnInFlight|TurnCancellationResult" Sources Tests` gives no result.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: `aRetryWithTwoSubmissionsSendsOneRunningOneSummedUsageUpdateAndOneIdle` drives two submissions, their `generationCall` events and one `answered` event with the chain total. It asserts one `running`, one `usage_update` with the sum, and one `idle`. The usage-sum test has the name `submissionUsageIsSummedIntoOneUsageUpdate`.
- [x] `Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift`: `anOverflowRetrySendsItsCompactionUpdateAndOneSummedUsageUpdate` drives an overflow retry: a submission, a compaction, a continuation submission and an `answered` event with the chain total. It asserts the compaction meter update, one summed `usage_update` with no second count, and one `running`.
- [x] Run `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue