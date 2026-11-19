---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tgn6mw04rkr6zaw8vdqb06
  text: |-
    Research: the ULID rule was in two places. `TranscriptSearchSessionCollector.admission(of:)` parsed each visible session id with `ULID(ulidString:)` and ignored each session that did not parse. `TranscriptSearchFilter` compared ULIDs, because `SessionSearchRequest.sessions`/`.session` of Multitool are `ULID`. `SessionSearchResult.session` of Multitool is a `ULID` too, so the client (TestudoApp `ClientTranscriptIndex`) cannot get a UUID session from that type. The date index (^w0dheny) and the catalog already use `SessionId`; the date index sorts by `sessionId.rawValue`, which works for each string.

    Implementation: the core search now uses `SessionId`. New public types: `TranscriptIndexSearchRequest` (with `init(_ SessionSearchRequest)`), `TranscriptIndexSearchResult`, `TranscriptIndexSearchPage`. New public overload `TranscriptSearchIndex.search(_ TranscriptIndexSearchRequest, visibleSessions:) -> TranscriptIndexSearchPage`. The old public `search(_ SessionSearchRequest, visibleSessions:) -> SessionSearchPage` does not change its signature: it searches only the visible sessions whose ids are ULIDs and gives ULIDs, so Multitool and `AgentTranscriptSearcher` do not change. Internal changes: `TranscriptSearchFilter.sessions/session` are `SessionId`, `admits(_:visible:)` takes a `SessionId`; `CollectedSession` has no `ulid`. ARCHITECTURE.md got one bullet about the two search forms.

    For the app: `ClientTranscriptIndex.search` must move to the new overload, and `sessions(matching:)` must give `Set<SessionId>` (not `compactMap ULID`). That is TestudoApp work; this repo does not change it.

    Discovery: an item id is `<session id>/<ordinal>`, so a free-form session id with a "/" can collide with a chunk item of another session. New task ^8qsp7hb.

    Test design note: with the word-bucket embedder, a word query also gives the other sessions (cosine), so the word tests assert the best session, not the whole list.
  timestamp: 2026-11-19T18:21:15.292098+00:00
- actor: claude-code
  id: 01m7tgn9khw21acrt02m3t9gmz
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Search/TranscriptIndexSearchRequest.swift (new), Sources/FoundationModelsACPAgent/Search/TranscriptIndexSearchPage.swift (new), Sources/FoundationModelsACPAgent/Search/TranscriptSearchIndex+Search.swift, Sources/FoundationModelsACPAgent/Search/TranscriptSearchFilter.swift, Sources/FoundationModelsACPAgent/Search/TranscriptSearchSessionCollector.swift, Tests/FoundationModelsACPAgentTests/TranscriptSearchSessionIdTests.swift (new, 10 tests), ARCHITECTURE.md. RED: 9 of 10 new tests failed against a stub (the Multitool guard test passed, as it must). GREEN: 121 TranscriptSearch tests pass, golden included.
    - next: review
  timestamp: 2026-11-19T18:21:18.321204+00:00
- actor: claude-code
  id: 01m7tgnb908jxpnzn05ewnk3ev
  text: |-
    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftPM note "missing creator for mutated node" of the mlx bundle). `timeout 1800 swift test --skip-build`: 2625 tests in 276 suites passed, 1 known issue (the existing withKnownIssue in HarnessSmokeTests), 0 failures. AgentTranscriptSearcherTests passed on the first run.
    - next: review
  timestamp: 2026-11-19T18:21:20.032147+00:00
position_column: doing
position_ordinal: '8180'
title: 'D207: the client transcript search index accepts any session id, not only a ULID'
---
Gap from the TestudoApp search work (2026-11-19).

## Current behavior

`TranscriptSearchIndex.search` gives back only sessions whose ids are ULIDs. The app's CLIENT index (`<AgentHome.local>/session-search/client/`) holds the sessions of other ACP agents, for example Claude Code, whose session ids are UUIDs or other strings. Those sessions never come back from a search.

## Change

1. The index accepts any session id string (the ACP `SessionId`). Keep the ULID rule only where the server needs it (for example where the agent maps a hit to a Router session, or where Multitool's `SessionSearchResult.session` is a `ULID`).
2. If a public type (for example a result type) carries a `ULID` where the client needs a string, add a string form for the client path, and say which types change. Do not break the Multitool protocol: the server searcher still gives ULIDs to Multitool.
3. Keep the ordering, filters, snippets and cursor the same.

## Dependency

Do this after ^w0dheny (the search speed task), because both change the search code.

## Tests

- A client index with a UUID session id and a free-form session id: a search returns them, with their hits and snippets.
- The server searcher still returns ULID sessions to Multitool, and the results are the same as before.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d207 #search