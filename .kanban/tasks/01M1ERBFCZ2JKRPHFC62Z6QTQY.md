---
assignees:
- claude-code
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
- 01KYSV83KNKXPSMJMQX5TFSPGC
- 01KYSV93N6D4RWYQ7XMCHQ21GW
position_column: todo
position_ordinal: 9d80
title: 'Elicitation relay: ACP elicitation/create and elicitation/complete over Router''s mailbox'
---
## What
Plan.md §16. Relay a tool's elicitation to the ACP client and deliver the answer back to Router. Work in `Sources/FoundationModelsACPAgent/Agent/ElicitationRelay.swift`.

**The wire is ready.** `FoundationModelsACP` vendored `schema-v2.0.0-alpha.3`. `ClientCapabilities.elicitation: ElicitationCapabilities?` carries `form` and `url` sub-objects. `AgentSideConnection.createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse` sends the request. `AgentSideConnection.elicitationComplete(_:)` sends the URL-mode completion. `CreateElicitationResponse` is a `JSONValue` typealias today, so decode `action` (`accept` / `decline` / `cancel`) and the optional `content` yourself.

**The Router seam is ready on the answer side.** `RoutedSession.respond(elicitationId: String, response: ElicitationResponse) async -> ElicitationAnswerDelivery` (`.delivered`, `.acceptedAwaitingCompletion`, `.noPendingElicitation`) and `RoutedSession.complete(elicitationId:) async -> ElicitationCompletionDelivery`. Extras' `ElicitationResponse` is `{ action: accept|decline|cancel, content: [String: ElicitationValue]? }`. Extras' `ElicitationRequest` is `{ mode: form|url, message, elicitationId: ULID, requestedSchema?, url? }`.

**BLOCKED upstream on the request side.** Router gives a host no public live signal that an elicitation is pending. `ToolContext.elicit(_:)` posts an `OperationEvent` with `kind: .elicitation` to the session outbox, but `SessionEvent` has no case for it, `SessionMailbox.pendingElicitationIds()` and `SessionOutbox.pending()` are internal, and `TranscriptEvent.operationEvents` is a recorded read, not a live one. Router's own tests reach the internal mailbox. File the ask (plan.md §21): one of a `SessionEvent` case on `streamSessionEvents()` that carries the `.elicitation` `OperationEvent`, or a public `RoutedSession.pendingElicitations()` read plus a wakeup. Do not start the relay until one lands. Do not poll the transcript.

Until the ask lands, keep the interim: decline every elicitation with the reason "this host cannot ask you questions yet". The MCP composition task already leaves `MCPServer.elicitationHandler` nil, because Router wins when present.

Build, once unblocked:
- Gate on `ClientCapabilities.elicitation` from `initialize`. Absent or null means unsupported. Check the mode: `form` and `url` are separate objects. When the needed mode is unsupported, answer Router with `decline` and a clear reason. Never fall back from `url` to `form`.
- Map Extras' `ElicitationRequest` to `CreateElicitationRequest`: `mode` (form: `message` + `requestedSchema`; url: `message` + `url` + `elicitationId`), scoped by `sessionId` and the run's `toolCallId` (= `completionToken`).
- Run each round trip inside Router's `awaitingUser { }` and pair it with `state_update: requires_action`, then back to `running` at the answer (§8.2).
- Map the client's answer to Extras' `ElicitationResponse` and call `respond(elicitationId:response:)`. On `.acceptedAwaitingCompletion`, relay MCP's completion through `elicitationComplete(_:)` and call `complete(elicitationId:)`.
- `session/cancel` and `session/close` answer every pending elicitation with `cancel` (§8.6, §10.1). `RoutedSession.close()` already rejects pending elicitations in its sweep.
- Obey the security duties: form mode never asks for secrets; URL-mode credentials never come back over ACP; `elicitationId` stays unique among outstanding URL elicitations on the connection; `elicitation/complete` goes only to the client that received the create.

- [ ] Upstream ask filed and linked here
- [ ] Capability gate on `ClientCapabilities.elicitation`, per mode
- [ ] Request mapping, form and url
- [ ] `requires_action` pairing inside `awaitingUser { }`
- [ ] Answer mapping and `respond` / `complete` delivery
- [ ] Cancel and close answer pending elicitations with `cancel`

## Acceptance Criteria
- [ ] A scripted tool that calls `ToolContext.elicit` in form mode produces one `elicitation/create` at the client, `state_update: requires_action` before it and `running` after the answer, and the tool receives the accepted content
- [ ] URL mode: create → accept → `elicitation/complete` reaches the client, and the tool resumes only after `complete(elicitationId:)`
- [ ] A client with no `elicitation` capability makes the tool receive `decline` with a reason, and no `elicitation/create` is sent
- [ ] A client with `form` only, asked in `url` mode, receives nothing, and the tool receives `decline`
- [ ] `session/cancel` during a pending elicitation delivers `cancel` to the tool before `idle(cancelled)`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ElicitationRelayTests.swift` — on the harness. Drive the client side with `SwiftUIACPClient.acceptElicitation(_:content:)`, `declineElicitation(_:)` and `pendingElicitations(for:)` from `FoundationModelsACPClient`; the client package's M7 is done
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.