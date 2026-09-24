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
depends_on:
- 01M3A30KQBCN1051EVS6KCTS5V
- 01M3A30WN7D2CB2X7EGM0K2VN6
position_column: todo
position_ordinal: '8480'
title: Adopt the Router request/attempt/pass names and the new request events
---
## Why

The Router task "Rename the turn level to request" (FoundationModelsRouter card `01M3A1F0KE9P9QPEVHXF33Q8GW`) is a breaking change. The Router has three levels: **request** (one `respond`/`stream` call), **attempt** (one `LanguageModelSession.respond` in a request; more than one after an overflow retry or a compaction continuation), and **pass** (one executor call, one generation).

This agent uses these Router symbols (measured 2026-09-24):
- `SessionEvent.turnStarted`: `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:185`.
- `SessionEvent.turnEnded(TokenUsage)`: `EventProjection.swift:264-273` sums usage and keeps the last `finishReason`. The comment there says "one event per inner generate call"; the Router card says it is one for each ATTEMPT. The new event contract settles this.
- `cancelCurrentTurn()` and its result: `PromptTurn.swift:652-655`, `SessionLifecycle.swift:217`.
- `TurnBoundaryTool.turnWillBegin()`: `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift:463`, `:483`.
- Tests with `.turnEnded(...)`: `PromptTurnTests.swift` (about 20), `CancellationTests.swift:97`, `EventProjectionTests.swift:639`, and `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift`.

## Coordination

The Router card says "update the consumers in the same change set". Only one agent must edit this repository. Before you start, read the Router card comments. If the Router agent already changed this repository, review its change against this task and complete what is missing. Write on the Router card which agent does this repository.

## External dependency

Router card `01M3A1F0KE9P9QPEVHXF33Q8GW` on Router `main`. Read the event choice (a) or (b) in its comments.

## What

1. `swift package update FoundationModelsRouter`.
2. `EventProjection.project(_:)`: map the request-start event to `turnState.turnDidStart()` (this sends `running` one time for each request). Sum the usage from the event that carries `TokenUsage` for each attempt. `lastFinishReason` comes from the last attempt. Ignore a request-end event if it carries no new data, or use its usage in place of the sum if the Router gives a request total (do not count twice).
3. Rename the cancel calls and the result cases in `PromptTurn.swift` and `SessionLifecycle.swift`, and the log text `cancelCurrentTurn ->`.
4. Update the tests above to the new names. Do not change what a test asserts, only the names, except where the event contract changed.
5. Keep the ACP words: `end_turn` (`StopReason.endTurn`), `max_turn_requests`, "prompt turn" in the ACP sense.

## Acceptance Criteria

- [ ] `swift build` and `swift build --build-tests` pass with the new Router.
- [ ] A request with an overflow retry (two attempts) sends one `running`, one summed `usage_update`, and one `idle`.
- [ ] The usage of each attempt is counted one time only.
- [ ] `rg -n "turnStarted|turnEnded|cancelCurrentTurn|turnWillBegin|noTurnInFlight|TurnCancellationResult" Sources Tests` gives no result.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift`: update the retry test at `:251` to the new events and assert one `running` and one `usage_update`; update `turnEndedUsageIsSummedIntoOneUsageUpdate` (rename it to `attemptUsageIsSummedIntoOneUsageUpdate`).
- [ ] `Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift`: a request-end event with usage, if the Router gives one, adds no second count.
- [ ] Run `swift test`. All pass. Read the real test names in the output.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #generation-queue