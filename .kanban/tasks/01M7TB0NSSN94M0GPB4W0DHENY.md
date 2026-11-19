---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tdcxvzby8v0mpn7z0ttv8c
  text: |-
    Picked up. Research and profile (Benchmarks package, debug, 41,000 items, before any change):

    - Before: search "dba" median 352.9 / max 367.0 ms; "dtba" 343.7 / 383.6; "lba stea" 367.3 / 395.8; "from:tool" 213.3 / 220.4. Registry matches(for:) alone 147-185 ms.
    - Profile of one ranked search (about 330 ms): matches(for:) 180 ms (of which heldCatalog.count 6 ms: it builds the 41,000-item array only to count it); filter of 41,000 matches 126-134 ms (31,000 pass: each item parses a ULID, copies the chunk for the kind, and looks up the visible session); candidate wrap 12 ms; session grouping 15-20 ms; page (tokenize, 60 snippets) 13-17 ms.
    - Profile of the token-only search (about 210 ms): catalog build 5 ms; filter of 41,000 items 137-144 ms; sort by date 38-55 ms; page 40 ms. The page is slow because TranscriptSnippet.leading calls Tokenizer.tokenize on each word of the whole block, also with no query term (the result of that tokenize is never used then).
    - The registry returns one match for each item of the catalog (the fake embedder gives each item a cosine), so the ranked path must walk 41,000 matches. Each per-match step must be very cheap.
    - Snippets are already made only for the hits of the page (point 3 holds already); the cost is in the filter and the walk.
    - hitCount of a session counts all its admitted candidates, and the cursor needs the number of sessions, so a ranked walk cannot stop early. It can skip the text filter and the bookkeeping for each session that is not in the first offset+limit+1 sessions of its group (preferred folder or not).
  timestamp: 2026-11-19T17:24:18.431974+00:00
- actor: claude-code
  id: 01m7tffhbth70q4f55r0n5ftah
  text: |-
    Implementation landed (not committed). What changed:

    - New `TranscriptSearchDateIndex` (Search/TranscriptSearchDateIndex.swift): the chunk items newest first (date, then session id, then ordinal). `index(_:removing:)` changes it for each session whose chunk items changed and each removed session (an upsert, a remove and a reconcile all go through this call); the load makes it from the restored sessions. A change of at most 256 entries uses a binary search for each entry; a larger change filters and merges in one pass.
    - New `TranscriptSearchSessionCollector`: it keeps at most offset+limit+1 sessions in each group (preferred folder, other). A later session of a full group gets no session filter, no text filter, no candidate and no count. A token-only walk stops when it has its sessions (with a preferred folder, only when the preferred group is full), and only the sessions of the page get their hits (from their own chunk items).
    - `TranscriptSearchFilter`: the session filter runs one time for each session (ULID parse, sets, archive), when its first item comes and a group can still take it. Kinds and dates come before the phrases and the exclusions.
    - `matches(for:)`: the limit is the item count of the sessions, with no build of the 41,000-item catalog (6 ms).
    - `TranscriptSnippet`: a word skips the tokenize when no query term can match it (no query term; or an ASCII word whose lowercase holds no query term). A non-ASCII word always gets the tokenize, so the result is the same.
    - The token-only path waits for the load (`await load()`), as the old `catalog` read did. A test (`aQueryBeforeTheLoadListsTheStoredSessions`) failed with no wait and passes with it.

    Tests:
    - `TranscriptSearchGoldenTests` + `Tests/Fixtures/transcript-search-golden.json`: 16 requests x 2 embedders, up to 3 pages each through the cursor. The golden file was recorded from the old code BEFORE the change, and it stays green.
    - `TranscriptSearchDateOrderTests`: token-only order after upsert, remove, reconcile, load, and a query before the load. A mutation (no date-index update) fails all 5.
    - `TranscriptSearchDateIndexTests`: small and large changes keep the sorted order. A mutation (no merge, append) fails all 3.
    - `TranscriptSnippetTests`: a non-ASCII word matches; a longer token that holds the query word does not match.

    Benchmarks (debug, 41,000 items), before -> after (two runs of the final code):
    - "dba": 352.9/367.0 -> 191.1/203.3 and 201.3/235.3 (median/max ms); registry alone 171.7-183.4.
    - "dtba": 343.7/383.6 -> 170.1/190.5 and 171.8/187.5; registry alone 149.6-153.2.
    - "lba stea": 367.3/395.8 -> 195.9/202.6 and 220.0/230.6; registry alone 176.0-191.4.
    - "from:tool" (token-only): 213.3/220.4 -> 7.5/8.4 and 7.6/8.1.
    - Turn update: 25.2/32.4 -> 25.1/30.7.

    Where the time goes now (ranked query): registry `matches(for:)` 150-190 ms; the walk of the 41,000 matches 15-20 ms (only to iterate the 41,000 `Match` values in a debug build costs 10-12 ms); the page with 60 snippets 5-7 ms; the collector set-up under 1 ms. The max is under 300 ms in each run. The median is under 200 ms in the quiet run, but in a run where the registry alone took 183-191 ms, "dba" and "lba stea" were at 201 and 220 ms. This package adds about 20 ms after the registry; a median that is always under 200 ms needs a faster registry call (for example a filter or a limit in the registry), which is a design change outside this package.

    Discovery: `AgentTranscriptSearcherTests` is flaky on HEAD with no change (10 failed expectations in 30 repetitions). New task ^fr3d9xk.
  timestamp: 2026-11-19T18:00:41.082454+00:00
- actor: claude-code
  id: 01m7tffhyt7evfvsd0w74snjhr
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsACPAgent/Search/TranscriptSearchDateIndex.swift (new), TranscriptSearchSessionCollector.swift (new), TranscriptSearchFilter.swift, TranscriptSearchIndex.swift, TranscriptSearchIndex+Search.swift, TranscriptSnippet.swift; Tests/FoundationModelsACPAgentTests/TranscriptSearchGoldenTests.swift (new), TranscriptSearchDateOrderTests.swift (new), TranscriptSearchDateIndexTests.swift (new), TranscriptSnippetTests.swift; Tests/Fixtures/transcript-search-golden.json (new). swift test --skip-build: 2613 tests in 275 suites passed (1 known issue, the planned withKnownIssue in HarnessSmokeTests). Benchmarks: token-only 213 -> 7.5 ms; ranked medians 344-367 -> 170-196 (quiet run) / 172-220 (loaded run); max under 300 ms in each run.
    - next: /review. The median gate under 200 ms depends on the registry time (150-191 ms alone); this package adds about 20 ms.
  timestamp: 2026-11-19T18:00:41.690653+00:00
- actor: claude-code
  id: 01m7tfvwrdzychkd9r7e68ypgp
  text: |-
    ### review — findings
    - evidence: review sha 01ce2b7~1..01ce2b7; 1 finding (1 confirmed, 1 refuted; 7 tasks attempted, 0 failed); Sources/FoundationModelsACPAgent/Search/TranscriptSearchDateIndex.swift:128 code-hygiene/magic-numbers-swift
    - next: Replace the magic number with a named constant. Remove the same cause from all of TranscriptSearchDateIndex.swift. Then commit and review again.
  timestamp: 2026-11-19T18:07:25.965401+00:00
- actor: claude-code
  id: 01m7tfzwfwexct7tt8zdnvz147
  text: |-
    ### finish iteration 2 — implement and test
    - implement: changed — Sources/FoundationModelsACPAgent/Search/TranscriptSearchDateIndex.swift: the divisor of the binary search is the named constant `halvingDivisor`. The file has no other magic number. The finding is checked.
    - test: green — swift build --build-tests "Build complete!", 0 compiler warnings; swift test --skip-build: 2615 tests in 275 suites passed, 1 known issue (intended).
  timestamp: 2026-11-19T18:09:36.764086+00:00
position_column: review
position_ordinal: '80'
title: 'D207: the transcript search meets the 300 ms gate (date index, cheap filters first, snippets only for the returned hits)'
---
Request from the TestudoApp session (2026-11-19), after the measurement of ^y7nx1g3. Decision D207; the brief gives a 300 ms gate for a search.

## Current measurement (Benchmarks package, debug build, 1,000 sessions x 10 turns = 41,000 items, fake embedder 200 µs per text)

- Search, agent path: median 324–343 ms (max 462 ms). The registry `matches(for:)` alone: 141–183 ms. So about half of the time is in this package, after the registry.
- Token-only query (`from:tool`, no registry call): 204–211 ms. It sorts the whole catalog by date for each query.

## Change (in this package; do not change the registry or the ranking)

1. Keep a date-sorted index of the chunk items in `TranscriptSearchIndex` (update it on each upsert and remove), so a token-only query needs no full sort: it walks the index newest first and stops when the page is full.
2. Apply the cheap filters (visible sessions, `request.sessions`/`session`, archived, kinds, dates) BEFORE the expensive work (tokenizing for phrases and exclusions, snippets). Phrases and exclusions run only on the matches that pass the cheap filters.
3. Build snippets only for the hits that are returned: at most 3 for each session (or all with `session:`), and only for the sessions of the page.
4. Keep the same results: the same sessions, the same order, the same hits and snippets, the same cursor. Add a test that compares the new results with the old results for a fixed set of queries, before and after.

## Target

In the Benchmarks package: a search median under 200 ms and max under 300 ms; a token-only query well under that. Report the new numbers to the TestudoApp session (testudoapp-9a).

## Tests

- The results are the same as before for words, a phrase, `-word`, `from:`, `from:thought`, `after:`/`before:`, `session:`, a token-only query, and the cursor.
- The date index stays correct after an upsert, a remove, a reconcile and a load from the store.
- The Benchmarks package meets the target (run it; it is not in CI). #d207 #search #performance

## Review Findings (2026-11-19 12:01)

> Scope: `review sha 01ce2b7~1..01ce2b7` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 21 not reviewed.

> 20 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 20 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Tests/Fixtures/transcript-search-golden.json` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Search/TranscriptSearchDateIndex.swift:128` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
