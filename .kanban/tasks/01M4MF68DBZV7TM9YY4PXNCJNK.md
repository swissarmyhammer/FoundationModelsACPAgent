---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4mx1z785b49pymss0mqgwrs
  text: |-
    Research (Multitool checkout, OutputChunkStream.swift and OutputBuffer.swift):
    - `ShellOutputEvent` has no offset and no sequence number. `.output(stream:bytes:)` and `.gap(stream:droppedByteCount:)` only.
    - But the contract makes an exact per-stream offset possible on the consumer side: inside one stream of one run the events come in the order of the child, the delivered chunks joined are the output byte for byte, and each gap counts each dropped byte. Thus the sum of the output bytes and the gap counts of one stream of one run is the end offset of the last event in that stream. This is counting, not a comparison of bytes.
    - `ShellOutputSnapshot` gives `stdout.bytes` and `stderr.bytes`. When `truncated == false`, `bytes.count` is the end offset of that stream at the time of the call (the store takes each chunk before the budget test). When `truncated == true`, the stored bytes are not necessarily a prefix (OutputBuffer cuts an over-cap chunk to a safe boundary, and a later chunk can land past the hole). `storedByteCount` is shared by the two streams. Thus a truncated snapshot gives no offset.
    - Design: TerminalStream counts the delivered offset for each stream of each run, and records the snapshot end offset at each replacement. A later chunk that ends at or before that offset is dropped; a chunk that crosses it is trimmed. For a truncated snapshot there is no offset: the later chunks of that run are dropped until the completion replacement (which is the store in all cases). Multitool request for the exact truncated case: a per-stream end offset (count of all bytes that arrived for that stream, stored or not) on `ShellRawOutput`.
  timestamp: 2026-10-11T07:15:24.520444+00:00
- actor: claude-code
  id: 01m4mxxkh6acb13bre4nf2xsxq
  text: |-
    Implementation landed (TDD).
    - RED: 5 new tests in TerminalStreamTests failed for the expected reason (repeated bytes on the wire): aChunkQueuedBehindAGapReplacementSendsNoByteAgain, eachStreamDropsTheBytesThatTheReplacementHolds, aChunkThatCrossesTheReplacementSendsOnlyItsNewBytes, aTruncatedReplacementStopsTheChunksOfTheRun, aChunkQueuedBehindAWaitingRunReleaseSendsNoByteAgain. Each test checks the chunk bytes on the wire and the client view (replacement replaces, chunk appends) against the output of the run.
    - GREEN: new type `ShellRunByteLedger` (Agent/ShellRunByteLedger.swift). For each stream of a run it counts the delivered end (output bytes + gap counts) and keeps the end of the last replacement (`.offset(n)` from `bytes.count`, or `.unknown` for a truncated snapshot). `TerminalStream.project` advances the ledger for each event, also for a waiting run. `emit` sends only the bytes past the replacement end (drop or trim). `replaceOutput` (gap and waiting-run release) records the replacement end. `reportExit` removes the run from `announcedRuns` and from the ledger table.
    - No edit of the Multitool checkout, no path override, no byte comparison.
    - Follow-up for the truncated case: ^39h13a1 (Multitool request: per-stream `arrivedByteCount` on `ShellRawOutput`).
    - Build note: the "missing creator for mutated node ... mlx-swift_Cmlx.bundle" warning comes from Swift Build. It is in the RED log before any production change too (see ^tvjz12j).
  timestamp: 2026-10-11T07:30:30.054966+00:00
- actor: claude-code
  id: 01m4mxxpcezdjdx5wbaan6213s
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Agent/ShellRunByteLedger.swift (new), Sources/FoundationModelsACPAgent/Agent/TerminalStream.swift, Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift. `swift test --scratch-path .build/alt --force-resolved-versions`: 907 tests in 99 suites passed (1 planned withKnownIssue in HarnessSmokeTests, there before). `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions`: 35 tests in 13 suites passed.
    - next: /review
  timestamp: 2026-10-11T07:30:32.974758+00:00
- actor: claude-code
  id: 01m4myc8cytx904fqm3cnwyk3y
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 1bb0deb). 3 files reviewed, 7 validator runs attempted, 0 failed. Counts: 0 findings, 0 confirmed, 0 refuted. The .kanban files are excluded by .reviewignore.
    - acceptance: all 3 acceptance items are checked. No prior review findings sections.
    - next: none. The task is in done.
  timestamp: 2026-10-11T07:38:30.174498+00:00
- actor: claude-code
  id: 01m4myr2sc1reenkb7zq2vxbr7
  text: |-
    ### implement — changed
    - Coordinator request: make `eachStreamDropsTheBytesThatTheReplacementHolds` fail for a ledger with one shared offset for the run.
    - New scenario: stdout AAAA, stderr err1, gap(stdout, 4), stderr err2, stdout CCCC. Snapshot stdout AAAABBBBCCCC, stderr err1. Expected wire chunks AAAA + err1 + err2 (CCCC dropped). Expected client view AAAABBBBCCCC + err1 + err2.
    - Proof: a temporary break in ShellRunByteLedger (all events on one key, replacement end = stdout + stderr counts) made this test fail at both expectations (and also aTruncatedReplacementStopsTheChunksOfTheRun, because the break ignored truncation). The break is removed: `git diff -- Sources/` is empty against 1bb0deb.
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/TerminalStreamTests.swift. `swift test --scratch-path .build/alt --force-resolved-versions --filter TerminalStreamTests` (new empty SKILLS_MARKETPLACE_CACHE): broken ledger 2 tests failed of 17; restored ledger 17 of 17 passed. Not staged, not committed.
    - next: commit the test change
  timestamp: 2026-10-11T07:44:57.644747+00:00
position_column: done
position_ordinal: ffc380
title: Do not send shell bytes again after a snapshot replacement
---
## Problem

`TerminalStream` sends one replacement from `snapshot(for:)` in two cases: at a `gap` event, and at the release of a run that waited for its join (^9xk3xf4). `snapshot(for:)` gives all stored bytes of the run. This includes the bytes of chunks that are still in the upstream queue of `ShellOutputChunkStream`. Thus a later `output` chunk of that run can send bytes that the replacement already has, and the client shows these bytes two times.

## What to change

- Make the replacement and the later chunks agree on one byte offset. For example: the snapshot gives its end offset, and `TerminalStream` drops (or trims) each later chunk of that run that ends at or before this offset. If the chunk events have no offset, find the smallest change in Multitool that gives one, and record it as a Multitool request.

## Acceptance

- [x] After a gap replacement, no byte of the run goes on the wire two times.
- [x] After the release of a waiting run, no byte of the run goes on the wire two times.
- [x] A test queues chunks behind a replacement and checks the full byte sequence on the wire.

#terminal