---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m44fpf8xtx4bmh3jj3cc9pew
  text: 'Reported upstream: FoundationModelsCodeContext board, task 01M44FP5NA6QPK1SRAZDD74EXK ("Watcher.start() calls FSEventStreamStart on a Swift cooperative thread, and fseventsd serializes the starts"), written with `sah tool kanban` on 2026-10-04 because no CodeContext session runs. It holds the evidence and asks for: the start off the cooperative pool, a public seam to inject or turn off the FileEventSource, a test, and a push. This repository needs no change now: ^vjaka1g turned the code context off in the stub fixtures. When upstream pushes, move the CodeContext pin.'
  timestamp: 2026-10-04T22:14:05.341786+00:00
position_column: done
position_ordinal: ff9880
title: 'Report upstream: CodeContext Watcher.start() calls FSEventStreamStart on a Swift cooperative thread'
---
## Why

Found during ^vjaka1g. `CodeContext.start()` awaits `Watcher.start()`, which calls `FSEventsFileEventSource.start(rootDirectory:handler:)`. That method calls `FSEventStreamStart` synchronously on the calling thread, a thread of the Swift cooperative pool (FoundationModelsCodeContext e9f60bd, `Sources/FoundationModelsCodeContext/Index/Watcher.swift`).

`FSEventStreamStart` is a synchronous mach RPC to fseventsd (`f2d_register_rpc`). fseventsd registers the streams of the whole machine one at a time. Measured on 2026-10-04 on a 32-core machine at load average 30: one start takes 0.1 s to 0.3 s; ten starts at the same time take 9.5 s (mean 5.5 s each); forty take 13 s. While a start waits, it holds one cooperative thread. A `sample` of the test process showed many cooperative threads blocked in `FSEventStreamStart`, and many tests that ended at the same time.

The teardown (`FSEventStreamStop` / `Invalidate` / `Release`) already runs on a global dispatch queue, so `stop()` does not block.

## What to do

- Record the evidence in an upstream issue on FoundationModelsCodeContext.
- The upstream change: call `FSEventStreamStart` off the cooperative pool (for example on the watcher dispatch queue, with a continuation that resumes when the start returns), so a slow fseventsd blocks no cooperative thread. A public seam to inject a `FileEventSource` would also let a host or a test turn the watcher off.
- No local override in this repository.