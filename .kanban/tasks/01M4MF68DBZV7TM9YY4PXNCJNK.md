---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: Do not send shell bytes again after a snapshot replacement
---
## Problem

`TerminalStream` sends one replacement from `snapshot(for:)` in two cases: at a `gap` event, and at the release of a run that waited for its join (^9xk3xf4). `snapshot(for:)` gives all stored bytes of the run. This includes the bytes of chunks that are still in the upstream queue of `ShellOutputChunkStream`. Thus a later `output` chunk of that run can send bytes that the replacement already has, and the client shows these bytes two times.

## What to change

- Make the replacement and the later chunks agree on one byte offset. For example: the snapshot gives its end offset, and `TerminalStream` drops (or trims) each later chunk of that run that ends at or before this offset. If the chunk events have no offset, find the smallest change in Multitool that gives one, and record it as a Multitool request.

## Acceptance

- [ ] After a gap replacement, no byte of the run goes on the wire two times.
- [ ] After the release of a waiting run, no byte of the run goes on the wire two times.
- [ ] A test queues chunks behind a replacement and checks the full byte sequence on the wire.

#terminal