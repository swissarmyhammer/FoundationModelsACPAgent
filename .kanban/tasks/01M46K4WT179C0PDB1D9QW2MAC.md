---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'code-context watcher: markDirty fails 24,812 times in one bench run, and the log loses the cause (FoundationModelsCodeContext)'
---
## Where the code is

The code is in the sibling repo FoundationModelsCodeContext (`/Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext`). This task is on this board because the bench of this repo found the problem. Move it to the board of FoundationModelsCodeContext when that repo has the work.

## Why

Found in the SWE-bench run `bench/preds.code-context.jsonl` of 2026-10-05. The run log `bench/run.code-context.log` has 24,812 warnings "the watcher could not mark a changed file dirty" (`error.type=FoundationModelsCodeContext.CodeContextError`). They are for 2699 different files, with a peak of 479 per second. The agent edited few files in this run. All 14 files in the patches also got the warning, so `code_context` can give stale results for a file that the agent edited.

The log keeps only the error type. The cause is lost.

## How the code works now

- `Sources/FoundationModelsCodeContext/Index/Watcher.swift:241-274`: `applyChange(relativePath:kind:)` calls `store.markDirty(...)` at line 267. A failure logs the warning at lines 269-272 and the change is dropped. Nothing tries again.
- `Watcher.swift:281-286`: `failureMetadata(relativePath:error:)` keeps only `Log.errorType(of: error)`.
- `Sources/FoundationModelsCodeContext/Index/Store.swift:236-261`: `markDirty` is one `INSERT ... ON CONFLICT DO UPDATE` in `write(_:)`.
- `Store.swift:203-214`: `withDbAccess` wraps each SQLite error into `CodeContextError.storage(error.localizedDescription)`. The SQLite code is thus in the message, but the log does not keep the message.
- `Store.swift:123-125`: one `DatabasePool` on `.code-context/kit.db`.

## What to do

1. Log the message of `CodeContextError` (and the SQLite result code) in the watcher warnings. Do the same for the "could not delete a removed file" warning at `Watcher.swift:246-249`.
2. Run the bench again with one instance, and find the cause from the new detail (probable candidates, not yet proven: `SQLITE_BUSY` or `SQLITE_LOCKED` from writes that run at the same time in a burst; a database that the bench removed or replaced during a checkout).
3. Find what changes 2699 files in a run with few edits (for example, the clone and checkout of each instance, or the environment build).
4. Remove the cause. Make sure that a change that fails to mark a file dirty is not lost: try again, or mark the file for the next reconcile.

## Acceptance

- The warning holds the error detail.
- A bench run of one instance gives no "could not mark a changed file dirty" warning for a file that the agent edits, and `code_context` gives the new content of that file.
- The builds and tests of FoundationModelsCodeContext and of this repo pass with no warnings.

#code-context #upstream #bench