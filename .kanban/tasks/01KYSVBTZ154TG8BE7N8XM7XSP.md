---
assignees:
- claude-code
depends_on:
- 01KYSVA1A4HXA6RYSJBE2XERFM
- 01KYSV611EWFQQRRPJWR5JQ4H5
- 01KYSVA96FDQP14HPP38ZQ362W
position_column: todo
position_ordinal: '9180'
title: Permission modes and session/request_permission
---
## What
Plan.md §11.7 (wire + gating; the config codec landed earlier). Create `Sources/FoundationModelsACPAgent/Agent/PermissionBroker.swift`:

- Resolve the effective mode per tool from `PermissionsConfig`: `"*"` (default — never ask; shell `.ask` outcomes resolve as allow; MCP hints never gate), `policy` (defer to shell's `.ask` rules and MCP `destructiveHint`/`openWorldHint`), `ask` (every call asks). `"*"` never touches the deny floor — denials refuse with a message and no prompt.
- When asking: send `session/request_permission` with `{sessionId, title, options[≥1], description?, subject?}`. `subject: tool_call` carries a **full `ToolCallUpdate`**, and the ask happens **before** any `tool_call_update` for that call is sent — no pending call in the timeline for something refusable; the first update goes out at approval (§11.7). Wrap the wait in `requires_action` + Router's `awaitingUser { }` (§8.2).
- Register each outstanding ask in the pending-request table so the cancellation task's hook (§8.6) answers it `cancelled` on `session/cancel` — the wire-level proof of that interaction lives HERE.
- Options include `allow_always`/`reject_always`; persist those decisions through the shell capability's `ShellDecisionStore` with `.session` as the default remembered scope (§2.5).
- Results: `cancelled` or `selected(optionId)`; **an unknown/`other` result is a refusal, never an approval**.

- [ ] Effective-mode resolution per tool
- [ ] Ask-before-first-tool_call_update ordering
- [ ] `requires_action`/`awaitingUser` pairing + pending-table registration
- [ ] always-decision persistence via ShellDecisionStore
- [ ] Unknown result → refusal

## Acceptance Criteria
- [ ] Default config scripted tool turn: zero `session/request_permission` requests observed
- [ ] `permissions: ask`: the permission request arrives before any tool_call_update for that toolCallId; on refusal no tool_call_update ever arrives for it
- [ ] During the ask, a `state_update: requires_action` precedes it and `running` follows the answer
- [ ] Wire proof of §8.6: a turn blocked on a permission ask + `session/cancel` → the client's pending permission request resolves with the cancelled outcome AND the final update is `idle(cancelled)`
- [ ] `allow_always` answer → the same command in the same session does not ask again
- [ ] A denied-by-floor command refuses without a prompt even under `"*"`

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/PermissionBrokerTests.swift` — harness with configurable RecordingClient permission answers; ordering assertions incl. the cancel-during-ask case
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.