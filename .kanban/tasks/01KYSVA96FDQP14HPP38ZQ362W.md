---
assignees:
- claude-code
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
position_column: todo
position_ordinal: 8d80
title: 'Cancellation: session/cancel confirmation semantics'
---
## What
Plan.md §8.6. In `Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift` (+ a small `Cancellation.swift` if cleaner):

- `session/cancel` is a notification. On receipt: stop the turn's work (Router queue-side cancellation — in-flight model turns run to completion until Router's in-flight cancellation lands upstream; that limitation is documented, not worked around); then send `state_update: idle` with `stopReason: "cancelled"` strictly last — any post-cancel updates go out **before** the idle update.
- Provide the hook that answers pending `session/request_permission` requests with the **cancelled** outcome. The hook is exercised fully in the permission-broker task (which depends on this one) — here it is implemented against the session's pending-request table and unit-tested directly; the wire-level proof lives there.
- Send correct terminal tool statuses where we have them, but never hold the idle update waiting for them (§8.6).
- Cancel of an idle session is a no-op (nothing pending, no error).
- MCP `notifications/cancelled` is advisory — the honest result is "we stopped listening"; reflect that in the tool-call text for still-running detached calls.

- [ ] Turn stop + strict idle(cancelled) terminator ordering
- [ ] Pending-permission cancellation hook (wire proof in the permission task)
- [ ] Terminal tool statuses without holding the idle
- [ ] Idle-session cancel no-op

## Acceptance Criteria
- [ ] Cancelling a scripted long-running turn: the last update is `idle(cancelled)` and no update of any kind arrives after it
- [ ] The pending-request table's cancel path resolves a registered pending entry as cancelled (direct unit test)
- [ ] Cancelling an idle session produces no error and no state change

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/CancellationTests.swift` — harness with a long-running scripted turn; order assertions on the collector; pending-table unit test
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.