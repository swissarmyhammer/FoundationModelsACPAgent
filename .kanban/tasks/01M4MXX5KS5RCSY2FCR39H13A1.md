---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4nerh5tjcdmhzjqjkx6k6ng
  text: |-
    Research and pin move.
    - Multitool main now has `ShellRawOutput.arrivedByteCount` (8295a39) and two later commits (e4ad858, a00e883). The user said: reference Multitool through main. Both Package.resolved files now pin main.
    - Pin move problem: `swift package --scratch-path .build/alt resolve` with the pin removed keeps the old checkout of `.build/alt` (workspace-state says main @ 2f8ea80). A `git fetch` in `.build/alt/repositories/...` and `resolve FoundationModelsMultitool --branch main` did not help. What worked: resolve with a NEW EMPTY scratch path (in the scratchpad). Then `--force-resolved-versions` builds move the `.build/alt` checkout to the pin.
    - Second problem: a resolve that starts from a Package.resolved that an earlier resolve wrote moved `swiftsoup` 2.13.9 -> 2.14.1 in IntegrationTests. Start from the ORIGINAL file, remove only the Multitool pin.
    - Ledger design: `ShellRunByteLedger` already counts the event offset per stream (output bytes plus gap counts), and trims an output chunk against the replacement end by its start offset. A gap only moves the offset forward. Thus only `end(of:)` must change: use `arrivedByteCount` always, and remove `ReplacementEnd.unknown` (then `ReplacementEnd` has one case, so it becomes a plain `Int`).
    - Every gap event in `TerminalStream` takes a new snapshot. A gap that arrives after a snapshot and straddles it thus comes with a second snapshot; the test uses a provider that gives one snapshot for each call.
  timestamp: 2026-10-11T12:24:49.594172+00:00
- actor: claude-code
  id: 01m4nfp1pg6h1ebxwj2ax5df8e
  text: |-
    ### implement — changed
    - evidence: 2 source files — Sources/FoundationModelsACPAgent/Agent/ShellRunByteLedger.swift, Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift. Pins (git-ignored): Package.resolved and IntegrationTests/Package.resolved, Multitool 2f8ea80 -> a00e883 (main), no other pin moved (diff against backups: only originHash and the Multitool revision).
    - RED: `aTruncatedReplacementSendsTheChunksPastItsArrivedBytes` and `aGapThatStraddlesASnapshotMovesTheOffsetPastIt` failed (4 issues) before the ledger change. GREEN: TerminalStreamTests 18/18.
    - Full root: `swift test --scratch-path .build/alt --force-resolved-versions` 908 tests in 99 suites passed (1 known issue: the deliberate `withKnownIssue` in HarnessSmokeTests). IntegrationTests: 35 tests in 13 suites passed. The only warnings are from Swift Build (`missing creator for mutated node ... mlx-swift_Cmlx.bundle`, see ^tvjz12j) and from the C++ sources of the mlx-swift dependency; none are from project code.
    - Design: `ReplacementEnd` is gone (with `.unknown` removed it had one case); `StreamOffsets.replacementEnd` is an `Int`, and `end(of:)` returns `arrivedByteCount`. A gap only moves `deliveredEnd`; an output chunk is dropped or trimmed by its start offset against the replacement end.
    - next: /review
  timestamp: 2026-10-11T12:40:56.784130+00:00
position_column: doing
position_ordinal: '80'
title: 'Multitool request: a per-stream end offset on ShellRawOutput, so a truncated snapshot gives an offset'
---
## Problem

`TerminalStream` uses `ShellRunByteLedger` (^pxncjnk) to drop the bytes of a chunk that a snapshot replacement already holds. The ledger counts the offset of each stream from the events (output bytes plus gap counts). It takes the end offset of a replacement from `ShellRawOutput.bytes.count`. That count is the end offset only when `truncated == false`.

When `truncated == true`, `OutputBuffer` can cut an over-cap chunk to a safe boundary and store a later chunk past the hole. Thus the stored bytes are not a prefix, and `bytes.count` is not an offset. `storedByteCount` is shared by the two streams, so it is not an offset of one stream. Now the ledger stops all later chunks of a run after a truncated replacement, until the completion replacement. No byte goes on the wire two times, but the live view of that run stops.

## Multitool request (the smallest change)

- Add one field to `ShellRawOutput` in `Capabilities/Shell/OutputChunkStream.swift`: `arrivedByteCount: Int` — the count of all bytes of THIS stream that `send` gave to the store, stored or not. `OutputBuffer` must count it for each stream (today `totalBytesProcessed` counts the two streams together).
- This is the end offset of the stream at the time of the snapshot, also for a truncated capture.

Multitool shipped it in 8295a39. Both `Package.resolved` files now pin Multitool `main` (a00e883 at the time of the move).

## What to change here after Multitool ships it

- [x] `ShellRunByteLedger.end(of:)`: use `arrivedByteCount` as the offset in all cases, and remove `ReplacementEnd.unknown`.
- [x] A truncated replacement does not stop the chunks of the run: a chunk past `arrivedByteCount` goes on the wire.
- [x] Update the test `aTruncatedReplacementStopsTheChunksOfTheRun` in `TerminalStreamTests` to the new behavior.
- [x] Add a test for a gap that arrives after a snapshot and straddles it (request of the user).

#terminal