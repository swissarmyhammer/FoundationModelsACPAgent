---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: 'Multitool request: a per-stream end offset on ShellRawOutput, so a truncated snapshot gives an offset'
---
## Problem

`TerminalStream` uses `ShellRunByteLedger` (^pxncjnk) to drop the bytes of a chunk that a snapshot replacement already holds. The ledger counts the offset of each stream from the events (output bytes plus gap counts). It takes the end offset of a replacement from `ShellRawOutput.bytes.count`. That count is the end offset only when `truncated == false`.

When `truncated == true`, `OutputBuffer` can cut an over-cap chunk to a safe boundary and store a later chunk past the hole. Thus the stored bytes are not a prefix, and `bytes.count` is not an offset. `storedByteCount` is shared by the two streams, so it is not an offset of one stream. Now the ledger stops all later chunks of a run after a truncated replacement, until the completion replacement. No byte goes on the wire two times, but the live view of that run stops.

## Multitool request (the smallest change)

- Add one field to `ShellRawOutput` in `Capabilities/Shell/OutputChunkStream.swift`: `arrivedByteCount: Int` — the count of all bytes of THIS stream that `send` gave to the store, stored or not. `OutputBuffer` must count it for each stream (today `totalBytesProcessed` counts the two streams together).
- This is the end offset of the stream at the time of the snapshot, also for a truncated capture.

## What to change here after Multitool ships it

- [ ] `ShellRunByteLedger.end(of:)`: use `arrivedByteCount` as the offset in all cases, and remove `ReplacementEnd.unknown`.
- [ ] A truncated replacement does not stop the chunks of the run: a chunk past `arrivedByteCount` goes on the wire.
- [ ] Update the test `aTruncatedReplacementStopsTheChunksOfTheRun` in `TerminalStreamTests` to the new behavior.

#terminal