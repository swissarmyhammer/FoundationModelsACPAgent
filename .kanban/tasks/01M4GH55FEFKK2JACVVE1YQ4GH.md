---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4h96w6sxw8c21bv9st7fjws
  text: |-
    Context from session foundationmodelsacp-43 (2026-10-09). Router ^xhmws92 has green tests, but it is not reviewed or pushed yet.

    1. COMPILE BREAK when this package takes that Router commit: `SessionEvent.toolInvocation(record)` becomes `SessionEvent.toolInvocation(record, toolCallID:)`. In `Agent/EventProjection.swift`, change `case .toolInvocation(let record):` to `case .toolInvocation(let record, let toolCallID):`.
    2. `toolCallID` is the SDK `Transcript.ToolCall.id`, the same id that the `toolCall` event carries. It is nil when no call matches, for example for a record that opens between two answers. For a nil id, keep the current key (the completion token).
    3. Event order: open record, close record, `toolCallReport`, then (from the transcript diff) `toolCall` and the running `toolStatus`, then the completed or failed `toolStatus`, then `submissionEnded`. A background run can close after the submission ends.
    4. Thus the run record arrives BEFORE the SDK `toolCall` event. Use `toolCallID` as the wire `toolCallId` from the first update. The later `toolCall` and `toolStatus` events must patch that same call, and must not open a second one.
    5. Known limit: the Router matches by tool name only. Two parallel calls of the same tool in one round can swap their ids. Record this limit in a comment, and add a test that shows the current behavior.
  timestamp: 2026-10-09T21:30:50.457161+00:00
- actor: claude-code
  id: 01m4hdb2sfcr0yb4765phffcvm
  text: |-
    Status from session foundationmodelsacp-43 (2026-10-09): Router ^xhmws92 is done (tests green, review clean), in the local Router commits 7f20163b, 1b77ef2b and 29b60440 together with ^twha0gz. They are NOT pushed. The user decides the push. Do not start this task before the push.

    The same push adds `SessionEvent.toolDisplay(ToolDisplayEvent)` (see ^a6mndxz), which also breaks each exhaustive `switch` on `SessionEvent` in `Agent/EventProjection.swift`. Thus the first commit after the Router update must fix both breaks: add `.toolDisplay`, and change `case .toolInvocation(let record):` to `case .toolInvocation(let record, let toolCallID):`.
  timestamp: 2026-10-09T22:43:02.575911+00:00
- actor: claude-code
  id: 01m4hgxq8wz48caqdyzyg28g04
  text: 'Upstream status (session foundationmodelsacp-43, 2026-10-09): NOT READY. Router ^xhmws92 (7f20163b, 1b77ef2b, adds `toolInvocation(record, toolCallID:)`) is done and reviewed but NOT pushed. Known limit: Router matches the call by tool name only, so two parallel calls of one tool in one round can get the id of the other call. /finish skips this task until those Router commits are on origin/main.'
  timestamp: 2026-10-09T23:45:39.100259+00:00
- actor: claude-code
  id: 01m4jan159br9d9n8krkb32dzr
  text: 'Router is pushed (session foundationmodelsacp-43, 2026-10-10): origin/main holds 1b77ef2b (^xhmws92) and 29b60440 (^twha0gz). This task is READY. The Router move is done by ^a6mndxz if that task runs first; read its comments.'
  timestamp: 2026-10-10T07:15:17.289373+00:00
position_column: todo
position_ordinal: '8780'
title: Show one tool call for each tool run
---
## Goal

The ACP client must see one `toolCallId` for each tool run. Terminals are out of scope.

## Dependency

This task waits for FoundationModelsRouter task ^xhmws92 (01M4GH48AXA66MP44EGXHMWS92) "Join the SDK tool-call id with the run completion token". It is on the Router board. Do not start before it is on `origin/main` of FoundationModelsRouter.

## Problem

Now the client sees two tool calls for one run:

- the SDK call, in `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:562-606`
- the run call that is keyed on the completion token, `runCallUpdate`, at `EventProjection.swift:666-684`

## What to change

Use the joined id from the Router, so that both paths send their updates on the same `toolCallId`.

## Acceptance

- [ ] One tool run gives exactly one `tool_call` and its `tool_call_update` rows on one `toolCallId`.
- [ ] A background run that settles later updates the same `toolCallId`.
- [ ] A test reads the wire messages and counts the distinct `toolCallId` values for one run.