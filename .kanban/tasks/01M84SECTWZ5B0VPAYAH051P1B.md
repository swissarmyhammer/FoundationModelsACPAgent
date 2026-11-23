---
comments:
- actor: claude-code
  id: 01m84t0bhjfqmgq2j5jsr7n7tq
  text: |-
    Research done (implement step).
    - The dependencies are at FoundationModelsACP 7331f955 and FoundationModelsExtras 7f2f917c (swift package update of these two only).
    - MetadataWindows reads the tail 64 KB, then the tail 256 KB when the tail has no cwd, then the head 64 KB at offset 0 for a typed session. The head is always the read at offset 0 of a file larger than 256 KB. Thus a tail-only read of a grown file can use a byte source that gives no bytes for offset 0. ACP has no tail-only API.
    - SessionUpdateBatches gives no count of the skipped records. The copy (importSession) needs that count for SessionImportResult and the provenance, thus the copy keeps read(_ data:).
    - DotfolderWatcher of Extras uses DispatchSource, not FSEvents. The FSEvents technique of the family is FSEventsFileEventSource of FoundationModelsCodeContext (Index/Watcher.swift). The index uses that technique with a latency of 2 s, behind the file system seam.
    - The Multitool SessionImporter protocol (importable, importSession) stays until step 3. ImportableSessionsRequest has no automated field: importable gives the typed sessions only, and turnCount 0.
    - The repo has no opt-in test that an environment variable gates, and the test-partitioning validator forbids that gate. The opt-in real-disk test of section 7 is not in this step; a new task records it for IntegrationTests.
    - Plan: Import/ExternalSessionIndex.swift (actor), ExternalSessionFileSystem.swift (the seam, the local file system, FSEvents), ExternalSessionReadQueue.swift, ExternalSessionIndexFile.swift, ExternalSessionLayout (from ImportSourceScan.swift). AgentSessionImporter keeps importSession and reads the index for importable.
  timestamp: 2026-11-23T18:17:02.258512+00:00
- actor: claude-code
  id: 01m84wbb5vckrk3ey1apk4pr4b
  text: |-
    Implementation landed (not committed).
    - New: Import/ExternalSessionIndex.swift (the actor), ExternalSessionScan.swift (Step A find, Step B bounded read, tail-only read through HeadlessByteSource), ExternalSessionReadQueue.swift (two levels, newest first), ExternalSessionIndexFile.swift (format number 1, header with source and root), ExternalSessionRoot.swift, ExternalSessionIndexSupport.swift (folder match by cwd else project key, paging, events), ExternalSessionFileSystem.swift (the seam and the clock seam), LocalExternalSessionFileSystem.swift (disk and FSEvents, latency 2 s). ImportSourceScan.swift became ExternalSessionLayout.swift.
    - AgentSessionImporter is a struct over the index: importable reads the index only (typed sessions, turnCount 0, no wait); importSession finds its source in the index (a miss runs a find first). AgentHome.externalSessionIndexDirectory = local/external-sessions. RoutedACPAgent makes the index; shutdown stops it. ARCHITECTURE.md import section updated.
    - What did not work: the first find skipped each project folder (a depth check off by one), and the tests passed with nothing read; a require on the first build now guards that. A byte-by-byte join of the index file cost 45 s of CPU in a debug build; it now appends each line. Mutation checks: 11 of 13 mutations fail a test; the 2 others are equivalent (a second guard keeps the behavior).
    - Deviations: the copy keeps read(_ data:), because SessionUpdateBatches gives no count of the skipped records. The opt-in real-disk test is the new task ^m84w4dp (IntegrationTests), because an environment variable gate is forbidden here.
    - Extras/ACP should change: ExternalSessionError needs unknownSource and invalidCursor (the index has ExternalSessionIndexError now); ExternalSessionIndexState is global, the sidebar text needs a per-folder count; ACPImport needs a tail-only metadata read and a skipped count on SessionUpdateBatches.
  timestamp: 2026-11-23T18:57:59.483856+00:00
- actor: claude-code
  id: 01m84wbp2j6f0k2mvcm16ye140
  text: 'Correction: the task of the real-disk test is ^fpm8tjy, not ^m84w4dp.'
  timestamp: 2026-11-23T18:58:10.642249+00:00
- actor: claude-code
  id: 01m84wbp4ytaghrpp1j3rw2f2k
  text: |-
    ### implement — changed
    - evidence: swift test (full, one time, touched files): 2791 tests in 296 suites passed, 0 failures, 1 known issue (HarnessSmokeTests, withKnownIssue that was there before), no warnings from Sources/ or Tests/. New suites: ExternalSessionIndexScaleTests 14 tests (30,000 fake files), ExternalSessionIndexTests 17 test cases; AgentSessionImporterTests adapted (+2: typed filter, no turn count). Measured on the debug build: query during the build 22 ms (< 50 ms), cancelled follow 14 ms and cancelled query 22 ms to level 2 (< 100 ms), removed root 42 ms with 504 of 30,000 files opened (< 100 ms); full build: no full read, at most 4 reads at one time, each file at most 384 KB, no call over 256 KB, other files before the queried folder <= 4.
    - next: /review. Task left in doing.
  timestamp: 2026-11-23T18:58:10.718652+00:00
- actor: claude-code
  id: 01m8517dy9x1ymsjcyfzyrrx5w
  text: |-
    ### review — 6 findings, each fixed
    - 1. A second stop() released each FSEvents stream again. Fix: stop() returns early after the first stop; FSEventsExternalSessionWatch.stop() runs one time only (a Mutex flag).
    - 2. An import before the load of the index file ended could fail with unknownSource: install replaced the entries that the import added. Fix: install keeps the current entries; a found entry with the same stamp gives its place to the read entry of the file.
    - 3. An index released with no stop() kept its FSEvents stream and its event task. Fix: a deinit of the watch stops the stream.
    - 4. stop() and a removed root did not stop a running find. Fix: ExternalSessionFindCancel for each root, checked before each folder read; a cancelled find applies nothing, so a part of a find removes no entry.
    - 5. A layout folder that did not exist at the start of the watch (Codex archived_sessions) was never watched. Fix: the watch is partial, and a query runs finds as with no watch (at most one time in 30 s).
    - 6. Two finds of one scope cleared the finding state of each other. Fix: counts in place of flags.
    - The four time limits in ExternalSessionIndexScaleTests are replaced with checks of the work (user rule: no time limits in tests). One of them failed under load.
    - evidence: ExternalSessionIndexStopTests, 6 tests, each fails with its fix undone and passes with it. Full swift test: 2808 tests in 298 suites passed, 1 known issue (as before), no warnings from Sources/ or Tests/.
  timestamp: 2026-11-23T21:00:00+00:00
position_column: done
position_ordinal: ffffffc200
title: 'D212 step 2: ExternalSessionIndex, so the session list reads an index and never a full file'
---
Request from TestudoApp (decision D212, 2026-11-23; design TestudoApp/features/session-import-redesign.md sections 4 and 7). The most urgent step: the import list read each full session file of Claude Code (21 GB on one Mac) and froze Testudo with 15 GB of memory for 20 minutes.

Work:
- A new actor ExternalSessionIndex (4.1 to 4.5): step A find (a directory read with resource keys, no file opened), step B read with the bounded reader of FoundationModelsACP 7331f955 (metadata(from:) over FileByteSource), a two-level read queue (the folder that a client asks for now, newest first; then all other files, newest first), four workers at the utility priority with a cancel check before each file, no file I/O in the isolation of the actor.
- The index file external-sessions/<source>.jsonl in AgentHome.local, with a format number in the first line, an atomic replace after each 500 new entries and at the end of a build. A different format number or bad bytes cause a new build, with no error.
- FSEvents for each root (the technique of DotfolderWatcher), a latency of 2 s; a changed file is read at most one time in 30 s; a larger file with a known head gets a tail read only; a file that is gone loses its entry. With no stream, step A runs when a client asks, at most one time in 30 s.
- Queries read the index in memory and never wait for the build: the rows in the state read, and ExternalSessionIndexState (FoundationModelsExtras 7f2f917c). A folder query puts the files of its project key at level 1; it also compares the cwd of each entry with the folder. A cancelled query moves its files to level 2.
- A file system seam for tests.
- The old list operation (AgentSessionImporter.importable) reads the index. AgentSessionImporter keeps only the copy (importSession), and finds its source in the index.
- Move to the new readers of FoundationModelsACP; after this step, step 1b removes the old metadata(_ data:) API there.

Tests: section 7, FoundationModelsACPAgent part (a fake file system with 30,000 files in 60 project folders, sizes 100 KB to 60 MB, 93% automated, counting each call and the bytes).