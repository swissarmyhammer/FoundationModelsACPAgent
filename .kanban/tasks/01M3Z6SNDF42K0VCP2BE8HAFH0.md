---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3zbdvv66azfsrfshmhb933c
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — blocked on upstream FoundationModelsACP ^k55fg8a (Unstable compaction types) and ^zj1wfec (engine keeps a compaction entry); not on main yet, and the owner decides when they run
    - next: when that session sends the commit and the final type names, move the pin and run /implement on this card
  timestamp: 2026-10-02T22:23:16.838651+00:00
- actor: claude-code
  id: 01m40vyjc25zpfhgz387q7whps
  text: |-
    Unblocked: FoundationModelsACP main 60854b6 has the unstable compaction and notice types and the engine support (^k55fg8a, ^zj1wfec).
    ```swift
    let update = Unstable.CompactionUpdate(compactionId: id, status: .inProgress /* later .completed / .failed / .cancelled */,
                                           summary: .value(blocks) /* or .unchanged */, error: .unchanged, meta: .unchanged)
    let wire = try SessionUpdate(Unstable.SessionUpdate.compactionUpdate(update))
    // send `wire` as a normal session/update, and apply it to the SessionMergeEngine
    ```
    - Stream the summary with `Unstable.SessionUpdate.compactionSummaryChunk(Unstable.CompactionSummaryChunk(compactionId:content:meta:))` after the in_progress update and before the terminal update.
    - Optional live message: `Unstable.SessionUpdate.notice(Unstable.Notice(severity: .info, title: ..., description: ...))`; the engine returns `Change.notice` and does not store or replay it.
    - The engine keeps the compaction as an entry `SessionEntry.ID.compaction(id)` at a fixed position; `transcriptUpdates` replays it with its final status and summary. Keep replaying from the engine, never the Router transcript.
    - Check the exact initializer labels in `Sources/FoundationModelsACP/Generated/Unstable.Models.generated.swift`.
    Start after ^56jbp35 (one implementer in this tree at a time); move the pin to 60854b6 or later first.
  timestamp: 2026-10-03T12:31:15.842152+00:00
position_column: todo
position_ordinal: '8280'
title: Report each Router compaction as an ACP compaction entry, and keep the full ACP history across a compaction
---
## Why

Owner decision (relayed by the FoundationModelsACP session, 2026-10-02): a Router compaction changes only the model context. The ACP transcript keeps the full history, and a compaction shows as one more entry.

## Rules

1. When Router compacts (manual `/compact` or the auto-compaction budget), the agent removes or rewrites nothing in the ACP history. Earlier messages keep their IDs and content in the `SessionMergeEngine`.
2. The retained history for `session/resume` is the full engine transcript (`transcriptUpdates` / `stateUpdates`), never the Router transcript or journal (after a fold it holds a summary, with no ACP IDs). Card ^hkr6ykz sets up this replay.
3. Report each compaction with the upstream UNSTABLE ACP updates:
   - `compaction_update`: upsert by `compactionId`; `status` in_progress, then completed / failed / cancelled; the retained `summary: [ContentBlock]`; `error` on failure.
   - optional `compaction_summary_chunk` to stream the summary.
   - optional `notice` for a short live message (not stored, not replayed).
   - a `usage_update` with the new `used` value.
4. FoundationModelsACP gives only the types; it does not depend on Router.

## Blocked until

FoundationModelsACP pushes ^k55fg8a (the types in an `Unstable` namespace: `Unstable.SessionUpdate`, `CompactionUpdate`, `CompactionSummaryChunk`, `CompactionStatus`, `Notice`) and ^zj1wfec (the engine keeps a compaction as an entry and replays it). That session sends the commit and the final names. Do not start before then.

## What to do (when unblocked)

- Map Router's compaction events (`compactionStarted` / `compacted` / the shortfall / the failure, see `EventProjection` and `BuiltinCommands` `/compact`) to `compaction_update` with one `compactionId` per compaction, and stream the summary if Router gives it in parts.
- Send a `usage_update` with the new context use after the compaction.
- Apply each of these updates to the session engine, so a resume replays the compaction entry.
- Tests: a manual `/compact` gives in_progress then completed with the summary; a shortfall gives failed with the reason; earlier messages keep their IDs and content in the engine after the compaction; a resume replays the compaction entry. #upstream