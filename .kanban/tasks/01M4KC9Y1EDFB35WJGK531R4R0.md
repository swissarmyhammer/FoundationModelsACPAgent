---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
title: 'Keep the terminal status of a settled run: the later SDK toolCall and toolStatus updates must not write over it'
---
## Problem

Found during ^w7hzpmq. After ^e1yq4gh, the SDK `toolCall` and `toolStatus` events of a call go on the same wire id as the run events of that call. The SDK `toolCall` event comes after the SDK call returned, thus after the settlement of an inline run. `EventProjection.projectToolCall` always sends `status: in_progress`, and `projectToolStatus` then sends the status that Router derives from the transcript (`running`, then `completed`).

Thus a run that settled `failed` (for example `timedOut`) or `cancelled` can end on the client as `completed`. Between the two updates, the client also shows `in_progress` for a run that is done.

## What to change

- Find the order of the events for an inline run and for a background run from a real Router stream (a test with the scripted backend).
- When the wire call has a terminal status from a settlement, the SDK `toolCall` and `toolStatus` updates must not send a status over it.
- Keep the current behavior for a call that no run settled.

## Acceptance

- [ ] A test reads the wire messages: an inline run that settles `failed`, then the SDK `toolCall` and `toolStatus` events, ends `failed` on the client.
- [ ] A call with no settlement still ends with the status of `toolStatus`.