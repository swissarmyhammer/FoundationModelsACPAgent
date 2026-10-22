---
comments:
- actor: claude-code
  id: 01m5jhepr4jke5vmk22dgd9phb
  text: |-
    ### Scope after the user decision of 2026-10-22 (orchestrator)
    - The session parts of this card (sessions.jsonl through SessionIndex, tombstones, and TranscriptStore reading index.md) are superseded. The user eliminated sessions.jsonl, and sessions are listed from their folders and index.md. That work is ^am394r2 (01M5HK8QQRZ2E3HA6JSAM394R2), which waits on Router ^2cqepsd (index.md, in review) and ^16ken1m (ProjectStore). Router main already deleted SessionIndex (70a5d3b9), so a full `swift package update` breaks this repo until ^am394r2 lands. Update only the packages that a card needs.
    - `Sources/acp-agent/EventLineWriter.swift:274` writes plain-text event lines to a FileHandle (stderr or a pipe), never to a `.jsonl` file. No change.
    - REMAINING SCOPE of this card: the `--telemetry-file` writer (`Sources/acp-agent/TelemetryFileWriter.swift`) writes `.telemetry.jsonl`. Move it onto Extras JSONLFile, which landed in Extras f64228a.
      - Append mode, one full line in one write, fsync per line.
      - Keep the record format; the bench harness reads it (bench/*.py).
      - Update only FoundationModelsExtras (`swift package update FoundationModelsExtras`). If that update does not build with the pinned Router, stop and report.
  timestamp: 2026-10-22T19:29:51.876579+00:00
- actor: claude-code
  id: 01m5jhkg3b4sr8zy08bawvas1y
  text: |-
    ### implement — research
    - `swift package update FoundationModelsExtras` moved Extras 589f27e -> 78d2532 (contains f64228a, JSONLFile). Package.resolved is gitignored here, so the bump leaves no diff to commit. Router untouched.
    - JSONLFile.append opens the file per append (O_RDWR|O_APPEND|O_CREAT|O_CLOEXEC), heals a torn tail with a leading `\n`, writes one whole line in one write(2), fsyncs, closes. Its encoder is sortedKeys + withoutEscapingSlashes, same as the old writer, but it has NO nonConformingFloat strategy: an infinite/NaN JSONValue number would throw encodingFailed. The old writer wrote them as the strings "Infinity"/"-Infinity"/"NaN" (Extras tokens-per-second recorder can record an infinity). To keep the record format, the writer maps non-finite numbers to those strings before the append.
    - JSONLFile(url:) opens nothing, so the CLI usage error for an unusable `--telemetry-file` path (TelemetryBootstrap.makeWriter -> ValidationError) needs its own check at init: stat/access(2) on the file, or on its folder when the file is absent. No raw open of the .jsonl outside JSONLFile.
    - Callers: TelemetryBootstrap.makeWriter, TelemetryFileLogHandler, TelemetryFileTracer/Span, TelemetryFileMetrics all call only `init(path:)` and `write(_:)`; the signature stays.
  timestamp: 2026-10-22T19:32:28.907374+00:00
- actor: claude-code
  id: 01m5jht4rg5j3bpv3hxfzvft87
  text: |-
    ### implement — changed
    - evidence: a787fb1 — Sources/acp-agent/TelemetryFileWriter.swift, Tests/FoundationModelsACPAgentTests/TelemetryFileTests.swift. Extras bumped 589f27e -> 78d2532 with `swift package update FoundationModelsExtras` only (Package.resolved is gitignored; Router pin untouched, build fine).
    - TDD: 6 new tests. RED on the old writer: aRecordAfterATornLineStartsOnALineOfItsOwn, aRecordAfterTheFileWasRemovedMakesTheFileAgain (per-record O_APPEND open). Characterizations that pass on both and guard the format: aRecordIsOneLineWithSortedKeys (exact line), aNonFiniteNumberWritesAsItsText, aRecordAppendsAfterTheLinesAlreadyInTheFile, aTelemetryPathThatIsAFolderIsAUsageError. The existing concurrentWritesGiveWholeLinesOnly (8 tasks x 50 records of 16 KiB) stays green with no in-process lock around the append.
    - `swift test`: 1230 tests in 135 suites passed, 1 known issue (HarnessSmokeTests orderedSubsequenceAssertionChecksOrderWithGaps). The only build warning is the Swift Build "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line that was there before this change (Extras allowed the same warning in 78d2532). `python3 -m unittest discover -s bench`: 265 OK, 1 skipped ('swebench is not installed', environment).
    - Design notes: the Mutex is gone; an Atomic<Bool> keeps the "report the first dropped record to stderr once" rule. JSONLFile's encoder has no non-conforming float strategy, so the writer maps NaN/±Infinity (any depth) to their text before the append.
    - next: /review
  timestamp: 2026-10-22T19:36:06.672275+00:00
- actor: claude-code
  id: 01m5jhx6323ras5qe6c565cp4a
  text: |-
    ### test — green
    - evidence: touched all Sources/Tests swift files, `swift test` (debug, own targets recompiled) - 1230 tests in 135 suites passed, 1 known issue, 0 failures, 0 skipped, 0 warnings from package sources (only a SwiftPM build-system note: "missing creator for mutated node" for the dependency bundle mlx-swift_Cmlx.bundle). `python3 -m unittest discover -s bench` - 265 tests OK (skipped=1, the old swebench skip).
    - next: review. No code changed, nothing to commit.
  timestamp: 2026-10-22T19:37:46.338436+00:00
position_column: doing
position_ordinal: '80'
title: Move every JSONL write onto Extras JSONLFile, and read session folders from index.md
---
## What
The user decided (2026-10-22) that every `.jsonl` file in our packages is written and read through one Extras type, `JSONLFile`:
- It is append-only and opens the file in append mode.
- Each record goes out as one full line in a single unbuffered write, followed by an fsync.
- A removal is an appended tombstone record, never a rewrite. Readers fold the records so the last line for a key wins.

Router is also replacing each session folder's `session.json` and `facts.json` with one `index.md`: markdown with frontmatter, plus an open body. That card is 01M5HS4PZCZH6W43MM72CQEPSD on FoundationModelsRouter's board.

There is no backward compatibility (ARCHITECTURE.md), so there's no fallback to the old files.

This waits on the FoundationModelsExtras `JSONLFile` card, 01M5HS4C6FBNTAX30161HP0BS5, and on Router's JSONL card, 01M5HS4WD0VANN9Y288S9DFTDP. Both are on FoundationModelsRouter's board. Bump the pins when they land.

## Where
- `Sources/acp-agent/EventLineWriter.swift:274` writes lines with `write(contentsOf:)`. When its destination is a `.jsonl` file, move it onto JSONLFile.
- Snapshots (`SnapshotsCommand.swift`, `Agent/SnapshotInventory.swift`) and the session list (`PromptExecution.swift` `makeFirstActivity`, `SessionList.swift`): every `sessions.jsonl` and `.jsonl` access goes through Router's SessionIndex or through JSONLFile. A removal is a tombstone line.
- `Transcripts/TranscriptStore.swift` reads `session.json`. Switch it to `index.md`.

## Subtasks
- [x] Every `.jsonl` write and read goes through JSONLFile or Router's SessionIndex — the `--telemetry-file` writer (`TelemetryFileWriter`) now appends through Extras JSONLFile. EventLineWriter writes no `.jsonl` (no change). The sessions.jsonl / SessionIndex / SnapshotInventory / SessionList part is superseded: the user eliminated sessions.jsonl, and that work moved to ^am394r2.
- [ ] TranscriptStore reads index.md — superseded, not in this card's scope: moved to ^am394r2 (waits on Router ^2cqepsd and ^16ken1m).
- [x] `swift test` passes, zero warnings #cross-repo