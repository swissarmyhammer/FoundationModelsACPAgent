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
Plan.md §4.6 and §9's needs. Create `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift`.

**Router's tree reader is not public. Build the read side on the one public API.** A survey on 2026-08-31, verified against the source:
- `restoreSessionTree`, `RestoredSessionTree`, `transcriptTree(recordingRoot:)` and `makeLanguageModel(resuming:)` are internal.
- `TranscriptTree.load(under:)`, `TranscriptTree.roots`, `SessionNode` and `effectiveTranscript(forSession:view:)` are `package`.
- The only public read is `TranscriptEvent.merged(under: URL) throws -> [TranscriptEvent]`. It gives a flat `(ts, seq)`-sorted list with no tree.

So:
- Read with `merged(under:)`. Group the events by `sessionId`. Rebuild parentage from `parentId`. Both fields are public on `TranscriptEvent`, with `slot`, `seq`, `kind`, `text`, `tokensIn`, `tokensOut`, `ms` and `entry`.
- Do NOT reimplement Router's reader against `transcript.jsonl` and `session.json`. That forks the format.

**`SessionSidecar` gives you nothing. Do not plan to read it.** An earlier draft of this task said the sidecar exposes `agentSpawn`. That is wrong. `SessionSidecar` is a public struct, but **every stored property is internal**, `agentSpawn` included. What is public is only the nested type `AgentSpawn` and `init(from decoder:)`. So a caller can decode a `session.json` it already located and then read no field from it. Take BOTH facts you need — `parentId` and the spawn fact — from `TranscriptEvent`.

Build these:
- `sessions(inProject:)` — join the grouped events with the `sessions.jsonl` records for the title, updatedAt and ordered additionalDirectories.
- A paged variant for §9's cursor pagination. Sort by `updatedAt` descending with `sessionId` as the tiebreak. The cursor is an opaque token that encodes the sort key, not an offset, so it stays stable under concurrent writes with no duplicates and no skips. An invalid cursor gives an error. Enforce a page-size limit.
- `allProjects()` — through `projects.jsonl`, skipping stale entries.
- `transcript(for sessionID:)` — return the session's ordered `[TranscriptEvent]`. **This store never records and never restores.** Live restore is the resume task's problem and is blocked upstream.
- The listability predicate for §9: the session has a persisted transcript (a zero-turn session never wrote one) AND it is a root, meaning `parentId == nil` and no agent spawn. **Agent spawns do not occur in this iteration** (plan.md §11.3), but the predicate must already exclude them, because a later Multitool agents capability will make them. No tool starts one yet, so make the spawned-session fixture through `makeSession(agentSpawn:)`.

**Know the `seq` limit.** `seq` is global across directories only WITHIN one recorder instance, and it restarts at 0 per run. That is why `ts` is the primary sort key in `merged(under:)`. Do not treat `seq` as globally unique across runs.

- [ ] Read path built on `merged(under:)`, grouped by `sessionId`
- [ ] Parentage and the spawn fact both taken from `TranscriptEvent`, never the sidecar
- [ ] `sessions(inProject:)` with the record join
- [ ] Sort-key cursor pagination
- [ ] `allProjects()`
- [ ] Roots-only and has-transcript listability predicate

## Acceptance Criteria
- [ ] Sessions come back sorted updatedAt-descending, with a sessionId tiebreak, across page boundaries
- [ ] Adding a session between two page fetches makes no duplicate and skips no existing entry
- [ ] An invalid cursor gives an error; an unknown project directory gives an empty list, not an error
- [ ] A fork fixture is excluded because its `parentId` is set; a directory-less index entry is excluded
- [ ] A session with a recorded transcript but no index line still lists, from the scan
- [ ] Records from two separate recorder runs interleave correctly, which proves the sort does not rely on `seq` alone

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift` — fixture transcript directories in a temp project, a pagination walk asserting order and stability, and the listability matrix. The fixtures must come from driving real recorded sessions: no shipped `TranscriptRecorder` is reachable, because `.jsonl`, `.inMemory` and `.none` are internal, and `TranscriptEvent` has no public init.
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.