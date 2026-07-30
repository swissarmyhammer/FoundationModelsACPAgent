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
Plan.md §9. In `Sources/FoundationModelsACPAgent/Agent/SessionList.swift`:

- Wire `session/list` to `TranscriptStore`'s paged read: `cwd` filter → one directory read; unfiltered → cross-project via `projects.jsonl`. Unknown directory → **empty array, not an error**. The method is baseline, never capability-gated.
- `SessionInfo`: required `sessionId` + absolute `cwd`; we always fill `title`, `updatedAt` (RFC 3339), and the complete ordered `additionalDirectories` from the most recent activation (§4.6, §9).
- Pagination: request `cursor`, response `nextCursor`; opaque tokens; invalid cursor → error; page-size limit; sort `updatedAt` desc + `sessionId` tiebreak (the store already implements this — this task is the wire surface and its conformance behavior).
- Listability: active and **closed** sessions listed; deleted and zero-turn sessions not; roots only (§9's table).

- [ ] Wire handler over the store's paged read
- [ ] SessionInfo population
- [ ] Cursor round-trip on the wire
- [ ] Listability rules observed from the client end

## Acceptance Criteria
- [ ] Client-end walk of three pages sees every session exactly once in updatedAt-desc order
- [ ] `session/list(cwd: <nonexistent>)` → empty array success
- [ ] An invalid cursor → JSON-RPC error
- [ ] A closed session appears; a deleted one does not (fixture via store)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionListTests.swift` — harness + fixture transcript directories; multi-page client-end walk
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.