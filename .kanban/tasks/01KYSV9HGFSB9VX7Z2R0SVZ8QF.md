---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fvgccna00c8r1w53mm6eq6
  text: |-
    Research done. Facts found:

    - Wire surface: `AgentSideConnection.afterRespondingToCurrentRequest(_:)` binds a task-local hook list around each handler call. The hook runs on the dispatch task after the response is written. Each inbound request runs in its own task, so a second `session/prompt` and `session/cancel` reach the agent while a turn runs.
    - The agent does not hold the connection today. The factory `AgentSideConnection(stream:) { connection in ... }` gives the connection to the factory. I will add a nonisolated `bind(connection:)` seam on `RoutedACPAgent` (Mutex-held), and the harness will bind in `makeParts`.
    - `PromptResponse` has no stopReason. The stop reason rides on `StateUpdate.idle(IdleStateUpdate(stopReason:))`. ACP `StopReason`: endTurn, maxTokens, maxTurnRequests, refusal, cancelled, unknown(String).
    - Router `SessionEvent` has 13 cases; `TurnStart` has an internal init, so a test cannot construct `.turnStarted`. `TokenUsage` has a public init. The retry-turn test (two `turnEnded`, one `idle`) will drive the projection with a synthetic event stream through an update-sink seam; the harness cannot make Router emit a retry with the stub backend.
    - No upstream error type exists for a tool-loop cap. Router error enums are internal. Mapping design: an owned `TurnStop` intent enum (completed, refusal, cancelled, budgetExhausted, toolLoopCapped, failed) with a total `TurnStop -> StopReason` function, plus `classify(any Error) -> TurnStop` that reads `CancellationError` and public `LanguageModelSession.GenerationError` cases (guardrailViolation/refusal -> refusal, exceededContextWindowSize -> budget). An unmapped error becomes the `_error` extension value under plan.md §18. `GenerationError.Context(debugDescription:)` is public, so scripted tests can throw the real SDK errors.
    - The default session tool surface is Multitool code-mode (`runCode`, `searchTools`, `wait`) plus `skills`. A scripted call into those does real work or invokes the librarian tier, so the harness §8.1 order test scripts a text turn; tool events in the middle of a turn are covered by the synthetic projection test (this task maps tool events through the default arm only; §8.4 projection is a later task).
    - "Known but closed": no close task has landed. I add `.closed` to `SessionAvailability` (computed from a stored `isClosed`), plus an internal `markSessionClosed(_:)` seam the session-close task will drive; tests use it for the resume-hint case.
    - `sessions.jsonl`: `SessionIndex(root:)` + `append(SessionIndexRecord)` already exist; root = session recordingDirectory parent. Title = first non-empty line of the first prompt text.
  timestamp: 2026-09-02T01:25:01.973676+00:00
- actor: claude-code
  id: 01m1fw500jqaxvvrc6b4gy1v9w
  text: |-
    Implementation landed, TDD order kept: the test suite was written first and failed to compile (no `bind`, no `PromptTurn`), then the production code made it green.

    What landed:
    - `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift`: `prompt` accepts, marks the session busy, and defers the turn through `afterRespondingToCurrentRequest` — never a detached task. Order on the wire: `{}` -> `user_message` echo (agent-owned ULID messageId, content = the request blocks) -> first-activity `sessions.jsonl` append + `session_info_update` -> `running` (from `turnStarted`) -> chunks -> one summed `usage_update` when the meter has a stamp -> one `idle` with the stop reason, keyed on stream completion, never on a `turnEnded` count. `textReset` sends a whole-message `agent_message` replace with `content: []` on the same messageId. `TurnStop` intent enum + total `stopReason(for:)` + `classify(any Error)`: `CancellationError` -> cancelled, `LanguageModelError.guardrailViolation`/`.refusal` -> refusal, `.contextSizeExceeded` -> maxTokens, tool-loop arm -> maxTurnRequests (producer is a later task), unmapped -> `_error` under §18. `sessionCancel` records the request on the turn owner and calls `cancelCurrentTurn()`; the recorded request forces `cancelled` even when the model work runs to completion. Unknown id -> -32602 with the id in data; closed -> -32602 with "closed; resume it first"; busy -> -32600 with the reason.
    - `Sources/FoundationModelsACPAgent/Agent/TurnState.swift`: `TurnStateOwner` actor — running / requires_action paired with Router's `awaitingUser` (back to running on value or error) / idle with stopReason — plus the `post` send helper that logs and drops a failed notify.
    - `RoutedACPAgent.swift`: nonisolated Mutex-held `bind(connection:)` seam; the prompt/cancel stubs moved out.
    - `SessionSetup.swift`: `SessionAvailability` gains `closed`; `ActiveSession` now derives availability from `activeTurn`/`isClosed` and tracks `indexRecorded`.
    - Test support: `ScriptedTurnStep` gains `.fail(ScriptedFailure)` (real `LanguageModelError` values) and `.hold`; the harness binds the connection and takes a prebuilt (scripted) agent.

    Decisions worth knowing:
    - `LanguageModelSession.GenerationError` is deprecated on macOS 27; the classifier and the scripted failures use `LanguageModelError`, the vocabulary Router's own overflow recovery matches. Router only retries an overflow when a budget is set, and our sessions have none, so a scripted overflow propagates.
    - `TurnStart` has an internal init, so the retry case (two `turnEnded`, one `idle`) drives `PromptTurn.drive(events:)` with a synthetic stream through the update-sink seam. The harness order test scripts a text turn: the default session tools are Multitool code-mode plus skills, and a scripted call into them does real work; tool events in mid-turn are covered by the synthetic projection test, and their wire mapping is the §8.4 projection task.

    `swift test`: 175 tests, all pass, zero compiler warnings (the one pre-existing `withKnownIssue` in HarnessSmokeTests stays).

    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift, Sources/FoundationModelsACPAgent/Agent/TurnState.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedModel.swift, Tests/FoundationModelsACPAgentTests/Support/Harness.swift
    - next: test
  timestamp: 2026-09-02T01:36:17.426884+00:00
- actor: claude-code
  id: 01m1fwb3t7ysx0fp6j331ser7z
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted; 7 files reviewed (the 2 .kanban files are review-ignored)
    - next: done
  timestamp: 2026-09-02T01:39:37.927481+00:00
- actor: claude-code
  id: 01m1fwb9qzggmz8rb7ghee5rqj
  text: |-
    ### finish iteration 1 — done
    - implement: changed (8 files; TDD: red on compile, then green)
    - test: green (swift test — 175 tests in 19 suites, 0 failed, 0 skipped, 0 compiler warnings)
    - commit: 6cb0766
    - review: clean (review sha HEAD~1..HEAD — 0 findings)
  timestamp: 2026-09-02T01:39:43.999439+00:00
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSV93N6D4RWYQ7XMCHQ21GW
position_column: done
position_ordinal: 8d80
title: 'Prompt turn: acknowledge-then-notify, message echo, state machine, stop reasons'
---
## What
Plan.md §8.1–§8.3. Create `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift` and `TurnState.swift`.

- `session/prompt` returns `{}` at once on acceptance, through the wire's `AgentSideConnection.afterRespondingToCurrentRequest(_:)`. Never use a detached task that races the response. Order: `{}` → `user_message` echo → `state_update: running` → turn output → `idle` with a stopReason.
- The prompt echo is a MUST and is the source of truth for the agent-owned `messageId` (§8.1, §8.3). Generate the messageIds here. §8.3's upsert algebra governs all message updates: a whole message with `content: [X]` replaces accumulated chunks, a `*_chunk` appends, and a new id starts a new message.
- Drive the turn with `RoutedSession.streamEvents(to:maxTokens:)`. **Abandoning that stream cancels the turn**, so never drop it early by accident.
- A named turn-state owner per session: `running` at the start; `requires_action` whenever we are blocked on the human, paired with Router's `awaitingUser { }` so the model gate opens while we wait (§8.2); back to `running` on the answer; `idle` with a stopReason at the end. A busy session refuses a second `session/prompt` as a client error (§7.1).

**Count `turnEnded` correctly.** Router sends `turnEnded(TokenUsage)` once per inner generate call, not once per logical turn. A turn that retries after a recovered overflow sends one `turnStarted` and TWO `turnEnded`. Do not send `idle` on the first one. End the turn when the event stream finishes, not on a `turnEnded` count.

**Handle `textReset`.** It tells us to discard the text collected so far. Send a whole-message replace, not another chunk. The projection task owns the mapping; this task must not assume text only ever appends.

- `StopReason` mapping: completed gives `end_turn`; a guardrail refusal gives `refusal`; a cancel gives `cancelled`; a budget end gives `max_tokens`; a tool-loop cap gives `max_turn_requests`. **Catch `CancellationError` and map it.** It must never escape as a JSON-RPC error and never as `refusal`.
- The first recorded activity writes the `SessionIndex` record, deferred from session/new by §9's zero-turn rule, with the generated one-line title from the first user prompt. It also sends `session_info_update`.
- Router errors cannot be caught by type. Every Router error enum is internal, so catch `any Error` and map by intent.

- [ ] Respond-then-notify through `afterRespondingToCurrentRequest`
- [ ] `user_message` echo with a generated `messageId`
- [ ] Turn-state owner, including the `requires_action` and `awaitingUser` pairing
- [ ] Turn end driven by stream completion, not by a `turnEnded` count
- [ ] `textReset` handled as a replace
- [ ] StopReason mapping, including the CancellationError catch
- [ ] Index record and title at first activity, plus `session_info_update`

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/prompt` with an unknown `sessionId` gives JSON-RPC invalid params (`-32602`) with the id in `data`. A known but closed session gives `-32602` with the reason "closed; resume it first", because a closed session is resumable, not promptable. Never answer either with `{}` and `idle`.

## Acceptance Criteria
- [ ] `session/prompt` on an unknown id gives `-32602` and sends no `session/update`; on a closed id it gives `-32602` with the resume hint
- [ ] On the harness, a scripted "model calls tool X then says Y" turn produces client-end notifications in exactly the §8.1 order
- [ ] A scripted retry turn sends two `turnEnded` and exactly one `idle`
- [ ] A second `session/prompt` during a running turn gives an error and does not disturb the first
- [ ] A scripted cancellation surfaces as `idle` with `cancelled`, not an error
- [ ] After the first prompt, `sessions.jsonl` gains the session's record with a one-line title, absent before the prompt

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift` — on the harness: the order assertion, the busy refusal, the stop-reason matrix, the retry case, and the title and index timing
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.