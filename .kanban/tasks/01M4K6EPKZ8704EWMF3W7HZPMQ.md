---
assignees:
- claude-code
depends_on:
- 01M4GH55FEFKK2JACVVE1YQ4GH
position_column: todo
position_ordinal: '8e80'
title: 'Keep the title that a tool gives its call: later run updates must not write the op title again'
---
## Problem

Task ^a6mndxz sends a `.metadata` display event of a tool as a `tool_call_update` patch with the title of the tool (for example "Edit /repo/notes.txt"). Each other update of the run also sends a title: `EventProjection.runCallUpdate` gets `title: .value(op)` from the progress, the attachment report, the settlement and the display content replace. The settlement is always the last update of a run. Thus the client shows the `op` ("edit file") again after the run, and the title of the tool is lost.

## Why the run updates send the op title

Each run update can be the creation of the wire call, because the run call is keyed on the completion token and nothing else creates it. Task ^e1yq4gh changes the key of the run updates to the joined SDK tool-call id. After ^e1yq4gh, the SDK `toolCall` event (or the open invocation record) can be the one creation, and the later run updates can omit the title.

## What to change

- Do this task after ^e1yq4gh.
- Send the `op` title only on the update that creates the wire call. Omit the title on each later run update, so that a title from a `.metadata` display event stays.
- Note: the SDK `toolCall` creation arrives after the SDK call returned, thus after the display events of the call. It must not write its title over a title that a `.metadata` event already sent.

## Acceptance

- [ ] A run that sends a `.metadata` title, then progress, a report and a settlement, ends with the title of the tool on the client.
- [ ] A run with no `.metadata` title still shows the `op` (or the tool name) as its title.
- [ ] A test reads the wire messages for both cases.