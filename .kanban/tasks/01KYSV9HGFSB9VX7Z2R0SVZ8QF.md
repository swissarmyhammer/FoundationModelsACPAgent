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
Plan.md §8.1–§8.3. Create `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift` + `TurnState.swift`:

- `session/prompt` returns `{}` immediately on acceptance, using the wire's `AgentSideConnection.afterRespondingToCurrentRequest(_:)` — never a detached task racing the response (§8.1). Order: `{}` → `user_message` echo → `state_update: running` → turn output → `idle` + `stopReason`.
- The prompt echo is a MUST and is the source of truth for the agent-owned `messageId` (§8.1, §8.3). Generate `messageId`s here; the upsert algebra of §8.3 governs all message updates (whole-message with `content: [X]` replaces accumulated chunks; `*_chunk` appends; new id = new message).
- A named turn-state owner per session: `running` at start; `requires_action` whenever blocked on the human, paired with Router's `awaitingUser { }` so the model gate opens while we wait (§8.2); back to `running` on answer; `idle` + stopReason at end. Busy sessions refuse a second `session/prompt` as a client error (§7.1).
- `StopReason` mapping: completed → `end_turn`; guardrail refusal → `refusal`; cancel → `cancelled`; budget end → `max_tokens`; tool-loop cap → `max_turn_requests`. **Catch `CancellationError` and map it** — it must never escape as a JSON-RPC error or as `refusal` (§8.2).
- First recorded activity writes the `SessionIndex` record (deferred from session/new per §9's zero-turn rule) with the generated one-line title from the first user prompt, and emits `session_info_update` (§4.6, §8.4).

- [ ] Respond-then-notify via `afterRespondingToCurrentRequest`
- [ ] `user_message` echo with generated `messageId`
- [ ] Turn-state owner incl. `requires_action`/`awaitingUser` pairing
- [ ] StopReason mapping incl. CancellationError catch
- [ ] Index record + title at first activity, `session_info_update`

## Acceptance Criteria
- [ ] End to end on the harness: a scripted "model calls tool X then says Y" turn produces client-end notifications in exactly the §8.1 order
- [ ] A second `session/prompt` during a running turn errors without disturbing the first
- [ ] A scripted cancellation surfaces as `idle` + `cancelled`, not an error
- [ ] After the first prompt, `sessions.jsonl` gains the session's record with a one-line title (absent before the prompt)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift` — on the harness: order assertion, busy refusal, stop-reason matrix, title/index timing
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.