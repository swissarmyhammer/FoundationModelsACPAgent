---
assignees:
- claude-code
depends_on:
- 01KYSV6QHJ631K7T7FRF4B8338
position_column: todo
position_ordinal: '8780'
title: 'TranscriptStore: read side, cursor pagination, project browsing'
---
## What
Plan.md §4.6 (+§9's needs). Create `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift`:

- `sessions(inProject:)` — a plain directory read of `<project>/.<name>/transcripts/`, joined with the `sessions.jsonl` records (title, updatedAt, ordered additionalDirectories).
- A paged variant for §9's cursor pagination: sort by `updatedAt` **descending** with `sessionId` as tiebreak; the cursor is an opaque token that **encodes the sort key, not an offset** (stable under concurrent writes — no duplicates, no skips); invalid cursor → error; enforced page-size limit.
- `allProjects()` — via `projects.jsonl` (stale entries skipped).
- `transcript(for sessionID:)` — delegates reconstruction to Router (`TranscriptTree`); this store never records and never restores (ownership boundary in §4.6).
- Listability predicate for §9: has a persisted transcript (zero-turn sessions never wrote one) AND `parentId == nil && agentSpawn == nil` (roots only, from Router's sidecar) — closed sessions stay listed, deleted ones are gone (§4.2, §9).

- [ ] `sessions(inProject:)` + record join
- [ ] Sort-key cursor pagination
- [ ] `allProjects()`
- [ ] Roots-only + has-transcript listability predicate

## Acceptance Criteria
- [ ] Sessions come back sorted updatedAt-desc, sessionId tiebreak, across page boundaries
- [ ] Inserting a new session between two page fetches causes no duplicate and no skip of pre-existing entries
- [ ] An invalid cursor errors; an unknown project directory returns an empty list (not an error)
- [ ] A fork/agent-spawn fixture directory is excluded; a directory-less index entry is excluded

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift` — fixture transcript directories in a temp project; pagination walk asserting order/stability; listability matrix
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.