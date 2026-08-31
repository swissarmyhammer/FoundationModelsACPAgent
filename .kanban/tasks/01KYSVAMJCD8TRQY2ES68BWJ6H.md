---
assignees:
- claude-code
depends_on:
- 01KYSV7GHQ7049N8DW5NH9MYWS
- 01KYSV8M8HV7R9W51QG63BBYR8
position_column: todo
position_ordinal: '8e80'
title: 'session/list: paged, updatedAt-sorted, roots only'
---
## What
Plan.md §9. Work in `Sources/FoundationModelsACPAgent/Agent/SessionList.swift`.

- Wire `session/list` to `TranscriptStore`'s paged read. A `cwd` filter reads one project. Unfiltered goes cross-project through `projects.jsonl`. An unknown directory gives an empty array, not an error. The method is baseline and is never capability-gated.
- `SessionInfo`: `sessionId` and an absolute `cwd` are required. Always fill `title`, `updatedAt` (RFC 3339) and the complete ordered `additionalDirectories` from the most recent activation (§4.6, §9).
- Pagination: the request carries `cursor`, the response carries `nextCursor`. Tokens are opaque. An invalid cursor gives an error. Enforce a page-size limit. Sort by `updatedAt` descending with a `sessionId` tiebreak. The store implements that; this task is the wire surface and its conformance behavior.
- Listability: active and closed sessions are listed. Deleted and zero-turn sessions are not. Roots only (§9's table).

**The store reads through Router's one public API.** `TranscriptEvent.merged(under:)` gives a flat event list with no tree, so the store groups by `sessionId` and rebuilds parentage from `parentId`. This task consumes the store and must not reach for Router's tree reader, which is `package` and internal. See the TranscriptStore task.

**This task does not need the resume work.** Listing works today; only live restore is blocked upstream. Do not couple this task to that block.

- [ ] Wire handler over the store's paged read
- [ ] `SessionInfo` population
- [ ] Cursor round trip on the wire
- [ ] Listability rules observed from the client end

## Acceptance Criteria
- [ ] A client-end walk of three pages sees every session once, in updatedAt-descending order
- [ ] `session/list(cwd: <nonexistent>)` gives an empty array and success
- [ ] An invalid cursor gives a JSON-RPC error
- [ ] A closed session appears; a deleted one does not
- [ ] A fork does not appear, because its `parentId` is set

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionListTests.swift` — harness plus recorded fixture sessions, and a multi-page client-end walk
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.