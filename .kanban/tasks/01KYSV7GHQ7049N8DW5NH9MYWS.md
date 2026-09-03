---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fj4y9hbecr3w2eysrsc68k
  text: |-
    ### Research discoveries (implement, before code)

    - `TranscriptEvent.merged(under:)` is at `Recording/MergedTranscript.swift` in the Router. It reads each nested `transcript.jsonl` and sorts by `(ts, seq)`. The public fields on `TranscriptEvent` are `sessionId`, `parentId`, `slot`, `seq`, `kind`, `text`, `tokensIn`, `tokensOut`, `ms`, `entry`. The field `ts` is internal, so the store cannot read a time from an event.
    - Because `ts` is internal, `updatedAt` for a session with no index line must come from the file system scan (the same source `SessionIndex.rebuild` uses), not from the events.
    - Open risk, to verify by test: the source trace shows `RoutedLLM.makeSession(agentSpawn:)` constructs the session actor with `parentId: nil` and writes `agentSpawn` only into `session.json`. If that holds at run time, the merged event stream carries no spawn fact. The test fixture will show the truth.
    - Test fixtures: Router's own tests drive a stub backend that accumulates `.prompt` and `.response` `Transcript.Entry` values (`Tests/.../Helpers/StubSessionBackend.swift`), because the recorder derives events from `backend.transcriptEntries()` diffs. The `EchoSessionBackend` in this package records nothing, so the new tests need a stateful stub backend.
    - `profile.standard` and `profile.flash` are public `RoutedLLM` values; `makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)` and `fork(workingDirectory:)` are the public drivers.
    - A zero-turn session writes `session.json` at construction but no `transcript.jsonl` until the first recorded event, so "has a persisted transcript" equals "the session contributes at least one merged event".
  timestamp: 2026-09-01T22:41:29.905969+00:00
- actor: claude-code
  id: 01m1fjp1xqf71hs6s7cnbewnra
  text: |-
    ### Blocker found and verified by a live fixture (2026-09-01)

    The card says: "Take BOTH facts you need — parentId and the spawn fact — from TranscriptEvent." The parentage half is correct. The spawn half is not possible with the pinned Router revision (87c660b). Evidence from a real driven fixture (stub profile, `makeSession(agentSpawn:)`, one turn, then `TranscriptEvent.merged(under:)`):

    - A fork's events carry `parentId` set, and its directory nests in the parent directory. The fork exclusion works from the events.
    - An agent-spawned session's events ALL carry `parentId == nil`. Its `session.json` carries the `agentSpawn` object, but every stored property of `SessionSidecar` is internal, and the card forbids a private read of `session.json`.
    - No event field, and no `entry` payload field, carries the spawn fact. `RoutedLLM.makeSession` constructs the session actor with `parentId: nil` and threads `agentSpawn` only into the sidecar write (`RoutedSessionActor.init` -> `writeSidecarIfNew`).

    So the public event stream cannot separate an agent-spawned session from a plain root session. The plan (§4.2, §9) states the opposite; that premise is wrong against the source.

    Plan for this card: implement the whole store with the roots-only predicate the events CAN express (`parentId == nil` on every event, plus at least one persisted event). Every acceptance criterion on the card is implementable and will be tested, including the fork exclusion. A canary test drives the `makeSession(agentSpawn:)` fixture and pins the upstream gap, so it fails loudly the day the Router publishes a spawn fact — that is the signal to finish the predicate. The card's spawn-exclusion requirement itself stays open; a person must decide the upstream ask (for example: the Router stamps `parentId` on a spawned session's events, or publishes a spawn accessor). The final outcome of this pass is `stuck` with that one gap named, not `done`.
  timestamp: 2026-09-01T22:50:50.679286+00:00
- actor: claude-code
  id: 01m1fk1yg2xt1mh1svkfe9k7xt
  text: |-
    ### implement — changed
    - evidence: 5 files — `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift` (new), `Sources/FoundationModelsACPAgent/Transcripts/SessionIndex.swift` (`lastActivityDate` opened to internal for the scan fallback), `Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift` (new, 16 tests), `Tests/FoundationModelsACPAgentTests/TranscriptRecordingFixtures.swift` (new), `Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift` (loader and recordings-directory injection).
    - TDD: the suite was written first and failed with "cannot find type 'TranscriptStore' in scope"; the implementation then made all 16 tests pass.
    - Discovery recorded above as a blocker: the Router permits ONE live writer per recording root (`owner.lock`, released at deinit), so the two-recorder-runs test drives its runs sequentially in their own scopes.
    - The spawn-exclusion half of the listability predicate stays open (see the blocker comment); a canary test pins the gap.
    - next: `/test` over the whole suite.
    task: ^nh9myws
  timestamp: 2026-09-01T22:57:20.386117+00:00
- actor: claude-code
  id: 01m1fk33mz17x02jnq05nf96qr
  text: |-
    ### test — green
    - evidence: `swift test` — 111 tests in 13 suites passed, 0 failed, 0 skipped; `swift build --build-tests` — 0 warnings from this package's files.
    - next: `/commit`.
  timestamp: 2026-09-01T22:57:58.431440+00:00
- actor: claude-code
  id: 01m1fk3y5bsz1n512c6qrqzt9p
  text: |-
    ### commit — changed
    - evidence: f7623ea feat(transcripts): add the TranscriptStore read side with cursor pagination (7 files, 1008 insertions, 8 deletions; local, not pushed)
    - next: `/review`.
  timestamp: 2026-09-01T22:58:25.579491+00:00
- actor: claude-code
  id: 01m1fkbz0x9h716w1x34c707a7
  text: |-
    ### review — findings
    - evidence: 1 finding — `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift:301` (magic number in the cursor field-count check)
    - next: back to implement to fix the finding, then test, commit and re-review.
  timestamp: 2026-09-01T23:02:48.605962+00:00
- actor: claude-code
  id: 01m1fkc67hmq2p9nyvq6n27n5q
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (TranscriptStore, fixtures, 16 tests; spawn-fact blocker recorded and verified)
    - test: green (111 tests, 13 suites, 0 failed, 0 skipped, 0 warnings)
    - commit: f7623ea
    - review: findings (1 — TranscriptStore.swift:301 magic number)
  timestamp: 2026-09-01T23:02:55.985509+00:00
- actor: claude-code
  id: 01m1fkgc9frewdvta0g5fsx16e
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 9b52725 — 0 findings; the one prior finding (TranscriptStore.swift:301) is fixed and checked.
    - The task does NOT move to done: the card requirement "the spawn fact taken from TranscriptEvent" stays blocked upstream (see the blocker comment of 2026-09-01). The code review is clean, but the card is not complete, so the task stays in `review` for a person to decide the upstream ask.
    - next: a person decides the upstream Router ask (stamp `parentId` on a spawned session's events, or publish a spawn accessor), then the predicate and the canary test get finished.
  timestamp: 2026-09-01T23:05:13.263889+00:00
- actor: claude-code
  id: 01m1fkghzsq4722erxgf234rpe
  text: |-
    ### finish iteration 2 — stuck (one named gap; code clean)
    - implement: changed (named constant `cursorFieldCount` replaces the magic number; the finding is checked)
    - test: green (111 tests, 13 suites, 0 failed, 0 skipped, 0 warnings)
    - commit: 9b52725
    - review: clean (0 findings)
    - The loop stops here on purpose: the spawn-exclusion half of the listability predicate is a true conflict between the card and the pinned Router's public API, verified by a live fixture. The task stays in `review`. A person must decide the upstream ask. All acceptance criteria on the card pass; only the spawn-fact subtask stays open.
  timestamp: 2026-09-01T23:05:19.097590+00:00
- actor: claude-code
  id: 01m1jf0jdz4b1rfcy6hz84zm4v
  text: |-
    ### Dependency update and spawn-fact verification (2026-09-02)

    - `swift package update` pulled FoundationModelsRouter `ba55154` (was `87c660b`) and FoundationModelsMultitool `03e43bb`. Note: `Package.resolved` is in `.gitignore` on purpose (each family dependency tracks a branch), so no lock-file change can go into a commit.
    - The spawn fact now exists on the public event surface. Evidence: `.build/checkouts/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:97` — `public let agentSpawn: SessionSidecar.AgentSpawn?`. The doc says: set only on the `Kind.session` event of a session made with an `agentSpawn`; `nil` for a root session, for a fork, on every other kind, and on a v1 recording.
    - `swift build` completes, but the update adds two new `SessionEvent` cases (`toolCallReport`, `elicitationRequested`) that cause one exhaustiveness warning in `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift:146`. This adaptation is part of this checkpoint. Full projection of the two new events is new work for a new task.
  timestamp: 2026-09-03T01:44:24.255965+00:00
- actor: claude-code
  id: 01m1jf7zna72aycn66pyykmg6f
  text: |-
    ### implement — changed
    - evidence: 2 files — `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift` (the listability predicate now requires `agentSpawn == nil` on every event; the doc says why), `Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift` (the canary test became the real spawn-exclusion test; it drives the fixture through `makeSession(agentSpawn:)`, asserts the events carry the spawn fact with `parentId == nil`, and asserts the spawned session does not list). Plus the update adaptation: `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift` gained explicit arms for the two new `SessionEvent` cases (`toolCallReport`, `elicitationRequested`) to remove the exhaustiveness warning; both arms log only, and the new task `^9vjyddw` tracks the real wire projection.
    - TDD: the rewritten test failed first at the ids assertion only ("Expectation failed: ids == [parent.description]"), which proves the fixture writes the spawn fact and the predicate did not read it; the one-line predicate change made it pass.
    - All subtask and acceptance boxes on the card are now checked.
    - next: `/test`.
    task: ^nh9myws
  timestamp: 2026-09-03T01:48:27.178416+00:00
- actor: claude-code
  id: 01m1jf854076s4eaadb53j95n4
  text: |-
    ### test — green
    - evidence: `swift test` — 301 tests in 34 suites passed, 0 failed, 0 skipped; the "1 known issue" is the pre-existing intentional `withKnownIssue` in `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift` (the reversed-pair order check), not a failure. `swift build --build-tests` — 0 warnings from this package's files.
    - next: `/commit`.
    task: ^nh9myws
  timestamp: 2026-09-03T01:48:32.768301+00:00
depends_on:
- 01KYSV6QHJ631K7T7FRF4B8338
position_column: review
position_ordinal: '80'
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

- [x] Read path built on `merged(under:)`, grouped by `sessionId`
- [x] Parentage and the spawn fact both taken from `TranscriptEvent`, never the sidecar — the Router update (revision `ba55154`) put the public `agentSpawn` field on `TranscriptEvent`, which unblocked the spawn half
- [x] `sessions(inProject:)` with the record join
- [x] Sort-key cursor pagination
- [x] `allProjects()`
- [x] Roots-only and has-transcript listability predicate — `parentId == nil` and `agentSpawn == nil` on every event

## Acceptance Criteria
- [x] Sessions come back sorted updatedAt-descending, with a sessionId tiebreak, across page boundaries
- [x] Adding a session between two page fetches makes no duplicate and skips no existing entry
- [x] An invalid cursor gives an error; an unknown project directory gives an empty list, not an error
- [x] A fork fixture is excluded because its `parentId` is set; a directory-less index entry is excluded
- [x] A session with a recorded transcript but no index line still lists, from the scan
- [x] Records from two separate recorder runs interleave correctly, which proves the sort does not rely on `seq` alone
- [x] An agent-spawned session (made through `makeSession(agentSpawn:)`) is excluded from the listing through the `agentSpawn` fact on its `session` event

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift` — fixture transcript directories in a temp project, a pagination walk asserting order and stability, and the listability matrix. The fixtures must come from driving real recorded sessions: no shipped `TranscriptRecorder` is reachable, because `.jsonl`, `.inMemory` and `.none` are internal, and `TranscriptEvent` has no public init.
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-01 17:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Transcripts/TranscriptStore.swift:301` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.