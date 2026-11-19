---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7sydsg6aq0v3a49xem3c28p
  text: |-
    Dependency available (2026-11-19): FoundationModelsACP D207 chunker is on main at dd3a981.
    - `SessionSearchChunker.chunks(of: engine.entries, dates: [SessionEntry.ID: Date]) -> [SessionSearchChunk]`, with `turn`, `ordinal`, `kind` (`.user/.agent/.message/.tool/.plan/.thought`; raw value = the `from:` word), `author`, `date`, `title`, `text`, `entries: [EntryRange(id, range)]` (ranges in characters).
    - Dates: the wire has no date, so the chunker takes them from the agent. Give the date that the agent recorded for each entry (or only for the first entry of each turn); a chunk takes the date of its first entry that has one. With no dates, `date` is nil. Find where the agent records a date (for example the delivery records of ^ccx24tw, or the turn end) and give it; if the retained history has no date, add the date of each turn to it.
    - The hit `entryId` text: `SessionEntry.ID.searchHitID` (`<kind>:<wire id>`), parsed by `SessionEntry.ID(searchHitID:)`.
    - Limits: `maximumChunkLength` = 2,000 characters; `maximumToolTextLength` = 64 KB (UTF-8 bytes) for each tool call.
    This task can start.
  timestamp: 2026-11-19T13:02:38.086432+00:00
- actor: claude-code
  id: 01m7sza3fw2dvka4khaxmpsa6d
  text: |-
    Research and design (implement step):
    - Pins: FoundationModelsACP moved 602c14c -> dd3a981 with `swift package update FoundationModelsACP` (the only change in Package.resolved). FoundationModelsMetadataRegistry stays at c323cf2 (main); it is now a direct dependency (`metadataRegistryDependencyName` in `familyDependencyNames`, same URL and branch as Multitool and Kanban). Package.resolved has no new checkout.
    - Registry API used as it is: `MetadataSearcher(items: [], mode: .retrieval, embedder:)`, `update(items:)` with the full catalog, `search(intent:limit:)` with limit = the catalog count (the board search pattern). Note: with an embedder, each embedded item gets a cosine rank, so a search gives each item a match; the caller filters (^f71bbpe).
    - Dates: the retained history had no explicit date. The mail ids of the delivery records are ULIDs (a time is in them), but an action command echo has a UUID id and no delivery record, so not each turn has one. Thus `RetainedHistory.apply` now records `_entry_dated` (`EntryDateRecord`: the entry id as `searchHitID` and an ISO 8601 date) when an update adds a user message or a message between sessions. The record is in session-history.json, the replay and the Markdown export leave it out (`replayedTranscriptUpdates`), and no client gets it. `SessionMergeEngine.recordedEntryDates` gives each entry the date of the last dated entry at or before it, so each chunk of a turn has the date of its turn; `searchChunks` gives them to `SessionSearchChunker.chunks(of:dates:)`.
    - Items: `TranscriptSearchItem` (`Search/TranscriptSearchItem.swift`) with `.chunk(SessionSearchChunk)` or `.session(TranscriptSessionMetadata)`; custom Codable (the chunk is not Codable in ACP). The tool title is added as the first line only when the first line of the chunk text is not the title (a later piece of a long call).
    - Index: public actor `TranscriptSearchIndex(folder:embedder:modelID:readableFolder:)` with `index(session:chunks:metadata:)`, `remove(session:)`, `matches(for:)`. It keeps no file. A change of the catalog that a later change overtook gives the catalog again (actor reentrancy).
    - Agent: `RoutedACPAgent.transcriptSearchIndex` over `AgentHome.serverSessionSearchDirectory` (`<local>/session-search/server`), embedder `ProfileEmbedding(residentProfile.embedding)`, model id `embedding.chosen.stringValue`. The profile always has an embedding slot, so the agent always gives an embedder. `AgentHome.clientSessionSearchDirectory` is for the app. Updates are not connected.
    - For ^en1kt61: the agent gives `readableFolder` = each folder (`RoutedACPAgent.everyFolderIsReadable`); the reconcile task must take the rule from the host.
    - ARCHITECTURE.md has no section for the transcript search; it needs one when the updates land.
  timestamp: 2026-11-19T13:18:05.820566+00:00
- actor: claude-code
  id: 01m7szetxp4mns7wwvh5e40by6
  text: |-
    ### implement — changed
    - evidence: Package.swift (registry direct dependency); Sources/FoundationModelsACPAgent/Agent/EntryDateRecord.swift (new), Agent/SessionHistory.swift (dated records, replay filter), Configuration/AgentHome.swift (server and client session-search folders), RoutedACPAgent.swift (transcriptSearchIndex), Search/TranscriptSearchItem.swift, Search/TranscriptSessionMetadata.swift, Search/TranscriptSearchIndex.swift, Search/SessionMergeEngine+SearchChunks.swift, Search/RoutedACPAgent+TranscriptSearch.swift (new); Tests: TranscriptSearchItemTests, TranscriptSearchIndexTests, TranscriptSearchWiringTests, Support/WordBucketEmbedding.swift. Pins: FoundationModelsACP dd3a981, FoundationModelsMetadataRegistry c323cf2 (no new checkout).
    - RED seen for 23 of 25 new tests (stub API); theReplayLeavesOutTheRecordedDates was proved by a mutation (filter removed -> fails).
    - next: /review

    ### test — green
    - evidence: `swift build --build-tests` Build complete!, 0 compiler warnings; `timeout 1800 swift test --skip-build`: 2502 tests in 261 suites passed, 1 known issue (intended). The first full run had 1 failure in RedriveInterruptedRunsTests.theReplayOpensTheOriginalCallWhenNoHistoryWasWritten (backgroundList order); the suite passed 3/3 alone and the next full run passed. Recorded as a flake on ^jstmpxs (I cannot prove it is not related; the test removes the history files, so it has no dated records at the start).
    - next: /review
  timestamp: 2026-11-19T13:20:40.886250+00:00
position_column: doing
position_ordinal: '8180'
title: 'D207: the transcript search items and one MetadataSearcher, as a reusable TranscriptSearchIndex'
---
Decision D207 in `TestudoApp/features/decisions.md` (commit ba585e0). The user: use the existing metadata registry and ranker as they are. Brief: `/Users/wballard/github/swissarmyhammer/.briefs/search/acpa-brief.md`, the rule and change steps 1, 2, 3 and 8. Overview: `overview.md` in the same folder.

## Dependency (not on this board)

FoundationModelsACP on `main` with `SessionSearchChunker.chunks(of:)` (`acp-brief.md`). Do not start until the ACP sha comes.

## The rule

The search engine is one `MetadataSearcher` of FoundationModelsMetadataRegistry in the `.retrieval` mode, as it is. Its BM25, trigram and cosine signals, fused with RRF, decide which items match and their order. This package makes no store, no SQLite, no FTS5, no vector table, no candidate step, no cosine and no fusion of its own. No GRDB. When the registry does not do a necessary thing, report it to the TestudoApp session.

## Change

1. **Dependency:** declare FoundationModelsMetadataRegistry as a direct dependency with the URL and the floor that the family uses, so `Package.resolved` gets no new checkout.
2. **Items:** `TranscriptSearchItem: SearchableMetadata, Codable`, two kinds:
   - a chunk item for each chunk of `SessionSearchChunker.chunks(of:)`: id `<session id>/<ordinal>`; the block is the text of the chunk, with the title of a tool call as its first line; it keeps the session id, the turn index, the kind, the author, the date, and the wire ids with their ranges;
   - a session item for each session of the directory: id = session id; the block is the name, the slug, the tags, the folder, the agent name, the recap (D206) and the last summary (ROUTER-9), one on each line.
   Use the default `renderIndexedText(from:)`, `renderEmbeddedText(from:)` and `renderSummaryBlock()`. Do not make chunks in this package.
3. **Searcher:** one `MetadataSearcher<TranscriptSearchItem>`, mode `.retrieval`, default weights, with the `ProfileEmbedding` of the profile as its embedder (`Tools/ProfileEmbedding.swift:19`, made in `Tools/ToolCatalog.swift:450`); `nil` with no `embedding` slot (keyword signals only). If a second searcher over the same catalog is necessary, the two share one `SharedCatalogEmbedding`.
8. **Reusable index:** one public type, for example `TranscriptSearchIndex(folder:embedder:modelID:readableFolder:)`, with `index(session:chunks:metadata:)`, a remove of a session, and a search entry point. The agent uses it with `<AgentHome.local>/session-search/server/`; the Mac app uses a second instance with `.../client/`. One code, two folders. (The folder is used by the persistence task; until then keep no file.)

## Tests

- The items of a history: the ids, the blocks, the fields; the same items for the same history.
- A searcher with a fake embedder and with none finds a word of a chunk and a word of a session name.
- Two instances with different folders are independent. #d207 #search