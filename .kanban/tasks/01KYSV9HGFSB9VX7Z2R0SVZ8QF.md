---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSV93N6D4RWYQ7XMCHQ21GW
position_column: todo
position_ordinal: 8b80
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

## Acceptance Criteria
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