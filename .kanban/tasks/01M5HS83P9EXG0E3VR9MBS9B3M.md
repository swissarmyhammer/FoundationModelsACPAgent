---
position_column: todo
position_ordinal: '8180'
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
- [ ] Every `.jsonl` write and read goes through JSONLFile or Router's SessionIndex
- [ ] TranscriptStore reads index.md
- [ ] `swift test` passes, zero warnings #cross-repo