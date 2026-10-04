---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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