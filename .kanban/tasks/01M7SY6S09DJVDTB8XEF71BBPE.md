---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7sz7s0a29fq0cnsjhm2k00f
  text: |-
    Dependency available (2026-11-19): the searcher protocol is on FoundationModelsMultitool origin/main: 7c209658 and 35bd7e45 (head fed5e709). Public API (all Sendable, Equatable, Codable, with public memberwise inits):
    - `protocol SessionTranscriptSearcher: Sendable { func search(_ request: SessionSearchRequest) async throws -> SessionSearchPage }`
    - `SessionSearchRequest`: `query: SessionSearchQuery`, `sessions: Set<ULID>?` (nil = each visible session), `includeArchived`, `preferredFolder: URL?`, `session: ULID?`, `limit`, `cursor`.
    - `SessionSearchPage`: `sessions: [SessionSearchResult]`, `nextCursor`, `unavailableFolders: [URL]`.
    - `SessionSearchResult`: `session`, `score` (0...1), `hitCount`, `hits`. `SessionSearchHit`: `entryID`, `kind` (user, agent, message, tool, plan, thought, session), `author`, `date`, `snippet`, `ranges` (character offsets in the snippet), `terms`.
    - `SessionSearchQuery(parsing:timeZone:)`: `words`, `phrases`, `excluded`, `kinds` (default: all but thought; `from:thought` adds it), `after`/`before` (start of day), `rankingText` (the intent for the MetadataSearcher).
    - Multitool resolves the directory tokens (`@session`, tag, `agent:`, `folder:`, `is:archived`) into `sessions` and `includeArchived` BEFORE the searcher gets the request. The searcher applies the phrases, exclusions, kinds and dates as filters after the MetadataSearcher.
    - The host API (`SessionsTool(directory:exporter:searcher:)`, `SessionsGraph.endpoint(of:exporter:searcher:)`) comes next with Multitool ^45e2jww; until then, build and test the searcher, and connect it to the tool when that sha comes.
    This task waits only for ^jex3g34 on this board.
  timestamp: 2026-11-19T13:16:49.546897+00:00
depends_on:
- 01M7SY663TJBRCSAEXBJEX3G34
position_column: todo
position_ordinal: 8f80
title: 'D207: AgentTranscriptSearcher for the sessions tool and endpoint (filters on the matches, sessions, snippet)'
---
Decision D207, parts (c) and (e). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/search/acpa-brief.md`, change step 7.

## Dependencies

- ^jex3g34 (the items and the TranscriptSearchIndex).
- FoundationModelsMultitool on `main` with the `SessionTranscriptSearcher` protocol, its value types and the query parse (`mt-brief.md`). Not on this board: wait for the sha.

## Change

`AgentTranscriptSearcher: SessionTranscriptSearcher`, with a weak agent, as `AgentTranscriptExporter`. For a request:
1. A query with tokens and with no word does not call the registry: it gives the chunk items that pass the filters of step 3, newest first.
2. Else `search(intent: query.rankingText, limit: <the size of the catalog>)`: one match for each item, as the board search does (`FoundationModelsKanban/.../Search/TaskSearch.swift:62-91`).
3. The filters, on the matches, in this order (D207 (e)): the sessions of `request.sessions` (or each visible session); archived sessions only with `includeArchived`; the kinds of `query.kinds` (thoughts only with `from:thought`); `after` and `before` on the date of the chunk; each phrase of `query.phrases` must be in the text, and no word of `query.excluded` may be in it, both on the tokens of `Tokenizer.tokenize`. A session item passes the session filters, and it does not pass a `from:`, `after:` or `before:` token.
4. The sessions: the order of a session is the place of its first match; its score is the score of that match; the sessions of `preferredFolder` come first (D199 (d)).
5. The snippet (D207 (c) (3)): about 200 characters of the block of the best chunk of the session, around the part with the most query words, with `Tokenizer.tokenize`, cut at word ends, with `ranges` and `terms`. A match whose `signals` have no BM25 and no trigram score (cosine only) gives the start of its entry and no range. A match of a session item gives one hit of the kind `session` with the recap. The `entryID` of a hit is the wire id of the entry of the chunk that holds the snippet.
6. At most three hits for each session, or all with `session:`. The cursor is opaque. A folder in the result that the process cannot read goes into `unavailableFolders`.
7. Give the searcher to `SessionsTool` and to the endpoint (`Tools/ToolCatalog.swift`, `Tools/CatalogContext.swift`), as the exporter.

## Tests

With a fake embedder and with none: a word; a word of a session name (the session item); a phrase; `-word`; `from:` and `from:thought`; `after:` and `before:`; `@<session>`; `is:archived`; a query with only tokens; the order of the preferred folder; the snippet with its ranges and terms; a match with only cosine; the cursor; `session:`. #d207 #search