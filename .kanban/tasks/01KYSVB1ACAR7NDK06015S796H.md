---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1jh8gwr0vd4dybh53nfy05y
  text: |-
    Research complete. Facts found:

    - Router checkout ba55154 shows the API from the card without change: `restoreSession(id:recordingRoot:instructions:tools:)` is async throws on `RoutedModel where Container == any LoadedLLMContainer` (RoutedLLM). `recordedWorkingDirectory(ofSession:recordingRoot:)` is synchronous throws and returns the sidecar working directory. `RestoredSession.instructionsDivergencePhrase` is public.
    - `TranscriptEntryPayload.entryId` is internal. The public identity on a recorded event is each segment id (`SegmentPayload.text(id:content:)` and its peers) plus `seq` and `sessionId`. The replay message id will use the first segment id, with `<sessionId>-<seq>` as the fallback for an entry with no segments.
    - A fold checkpoint is a `.response` entry that carries a `.structure` segment with the schema name `FoundationModelsRouter.CompactionSegment` (CompactionSegment.swift, boundaryEntry). Replay must skip that shape.
    - `RoutedSession.streamEvents` drives `backend.streamResponse`. `TranscriptStubBackend` appends transcript entries only in `respond`, so the resume tests need a backend that appends `.prompt` and `.response` entries in `streamResponse` too, and a container that records the transcript handed to `makeSession(transcript:tools:)` and counts backend requests.
    - The recording root resolves from the request cwd (`transcripts.location`), so a mismatched cwd finds no session under the default `project` location. The mismatch test uses `transcripts: location: <absolute path>` in both project configs, so both cwds share one root and the pre-check sees the recorded cwd.
    - `RequestError.unknownSession(id:)` already gives `-32602` with the id in `data` (PromptTurn.swift). The resume handler maps `TranscriptTreeError.sessionNotFound` to it.
    - The missing-tool report will ride the `ResumeSessionResponse` `_meta` object, because `SessionUpdate` has no report kind and `_meta` is the ACP extension point.
    - Plan: split `composeSession` into a config-load stage and a compose stage, so the cwd pre-check runs after the config load and before the tool composition and the restore. Extract the session mount steps that `newSession` and `resumeSession` share.
  timestamp: 2026-09-03T02:23:41.976858+00:00
- actor: claude-code
  id: 01m1jj6ssbe6fe725e7ba9t36s
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Agent/SessionResume.swift (new), Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/ResumeSessionFixture.swift (new), Tests/FoundationModelsACPAgentTests/Support/FilesVerbSupport.swift (new), Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift, Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift
    - TDD: 13 failing tests first (all failed on the old method-not-found refusal), then the implementation; `swift test --filter SessionResumeTests` now passes 13 of 13.
    - Design notes:
      - The cwd pre-check runs through the synchronous `recordedWorkingDirectory` after the config load and before the composition and the restore. The mismatch test asserts the loader was never asked for another backend.
      - `TranscriptTreeError.sessionNotFound` maps to the existing `RequestError.unknownSession` (`-32602` with the id in `data`), on the pre-check and on the restore.
      - The instructions override rides `restoreSession(instructions:)`; the test asserts through the transcript the restored backend received, and pins `RestoredSession.instructionsDivergencePhrase` by symbol.
      - Replay is written over an internal `ReplayCursor` parameter (inclusive; `start` is the first variant). It sends whole-message upserts keyed by the recorded first segment id, skips fold checkpoints by the `FoundationModelsRouter.CompactionSegment` schema name, and never sends a chunk form. The card's "original messageId values" are the ids the recording itself holds: the live ids are not persisted, so the recorded segment id is the one stable identity, and a repeated replay sends the same ids.
      - `missingTools` rides the `ResumeSessionResponse` `_meta` object, because `SessionUpdate` has no report kind. The shell-verbs test records a roster that names `shell.execute` directly against the resident profile, then resumes with `tools.shell: false` newly set.
      - The resumed root set replaces the old one and is appended to `sessions.jsonl` when a record exists; a zero-record session defers to the first prompt per §9.
      - `session/new` and `session/resume` share `activateSession` and the split `loadSessionContext`/`composeSession(from:)` pipeline, so the reassembly is one code path.
    - next: run the full test suite.
    step: implement
    outcome: changed
    task: ^15s796h
  timestamp: 2026-09-03T02:40:14.123947+00:00
- actor: claude-code
  id: 01m1jj7jnkm5vnk940z75jy520
  text: |-
    ### test — green
    - evidence: `swift test` — 322 tests in 36 suites passed, 0 failures, 0 skipped, 1 known issue (the pre-existing withKnownIssue in HarnessSmokeTests). Baseline was 309 tests in 35 suites; the new SessionResumeTests suite adds 13. `swift build` shows no compiler warning from this package; the one "missing creator for mutated node" line is the pre-existing mlx-swift bundle note from the build system.
    - next: commit.
    step: test
    outcome: green
    task: ^15s796h
  timestamp: 2026-09-03T02:40:39.603818+00:00
- actor: claude-code
  id: 01m1jj87dfyxfztanxq3y3zgwr
  text: |-
    ### commit — changed
    - evidence: a141ceb feat(agent): implement session/resume with the cwd pre-check, restore, and whole-message replay — 10 files changed, 1655 insertions(+), 56 deletions(-). Local commit only; not pushed.
    - next: review HEAD~1..HEAD.
    step: commit
    outcome: changed
    task: ^15s796h
  timestamp: 2026-09-03T02:41:00.847598+00:00
- actor: claude-code
  id: 01m1jjgeztfbt2k2spem0htx07
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift:19 `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments. Counts: 1 finding, 1 confirmed, 0 refuted.
    - The findings section is appended to the card, and the card subtask and acceptance checkboxes are checked, because the tests prove each one.
    - next: remove the @Suite attribute in the new test file, re-test, commit, re-review.
    step: review
    outcome: findings
    task: ^15s796h
  timestamp: 2026-09-03T02:45:30.746975+00:00
- actor: claude-code
  id: 01m1jjgnrqym2p1qkhfs5jaypg
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files; TDD with 13 new SessionResumeTests, all failed first on the old refusal.
    - test: green — `swift test` 322 tests in 36 suites passed, 0 failures, 1 pre-existing known issue.
    - commit: changed — a141ceb feat(agent): implement session/resume with the cwd pre-check, restore, and whole-message replay.
    - review: findings — 1 finding: SessionResumeTests.swift:19 redundantSwiftTestingSuite (remove the argument-free @Suite attribute).
    - next: iteration 2 fixes the finding.
  timestamp: 2026-09-03T02:45:37.687837+00:00
- actor: claude-code
  id: 01m1jjjr610s3h465av2kc65y2
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift. Removed the argument-free @Suite attribute; the type declares its tests through @Test alone. The finding checkbox is checked.
    - next: full test run.
    step: implement
    outcome: changed
    task: ^15s796h
  timestamp: 2026-09-03T02:46:45.697627+00:00
- actor: claude-code
  id: 01m1jjjw9gt90wkm97mkn2r41s
  text: |-
    ### test — green
    - evidence: `swift test` — 322 tests in 36 suites passed, 0 failures, 0 skipped, 1 pre-existing known issue.
    - next: commit the fix.
    step: test
    outcome: green
    task: ^15s796h
  timestamp: 2026-09-03T02:46:49.904432+00:00
- actor: claude-code
  id: 01m1jjk6v6v83xr9htkw5m2f9k
  text: |-
    ### commit — changed
    - evidence: 038351a refactor(tests): remove the redundant argument-free Suite attribute from SessionResumeTests — 3 files changed (the test file plus the kanban state). Local commit only; not pushed.
    - next: review HEAD~1..HEAD.
    step: commit
    outcome: changed
    task: ^15s796h
  timestamp: 2026-09-03T02:47:00.710380+00:00
- actor: claude-code
  id: 01m1jjn5caj8wy53hv349x5saz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted; the one prior finding is checked. Task moved to done.
    step: review
    outcome: clean
    task: ^15s796h
  timestamp: 2026-09-03T02:48:04.746082+00:00
- actor: claude-code
  id: 01m1jjna2c6g0at3prtasn9kcq
  text: |-
    ### finish iteration 2 — done
    - implement: changed — removed the argument-free @Suite attribute from SessionResumeTests.swift; the finding checkbox is checked.
    - test: green — `swift test` 322 tests in 36 suites passed, 0 failures, 1 pre-existing known issue.
    - commit: changed — 038351a refactor(tests): remove the redundant argument-free Suite attribute from SessionResumeTests.
    - review: clean — 0 findings on HEAD~1..HEAD, every prior finding checked; task moved to done.
  timestamp: 2026-09-03T02:48:09.548848+00:00
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSV7GHQ7049N8DW5NH9MYWS
- 01KYSVA1A4HXA6RYSJBE2XERFM
position_column: done
position_ordinal: 9c80
title: 'session/resume: cwd equality, restore, replay as whole-message upserts'
---
## What
Plan.md §7.4 and §8.3. Work in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`.

**The upstream block is LIFTED.** Router published the restore surface on `main` at commit `587cfe7` (2026-08-31). Verified against their source. This task now waits only on its own dependencies.

## The API, verified

`Sources/FoundationModelsRouter/Recording/SessionRestoration.swift`

```swift
public func restoreSession(
    id: ULID,
    recordingRoot: URL? = nil,
    instructions: String? = nil,
    tools: [any Tool] = []
) async throws -> RestoredSession

public func recordedWorkingDirectory(
    ofSession id: ULID, recordingRoot: URL? = nil
) throws -> URL          // NOTE: synchronous, not async
```

`RestoredSession` carries `session: RoutedSession`, `configurationReport: SessionConfigurationRestorationReport` and `contextMismatches: [RestoredSession.ContextMismatch]`. `ContextMismatch` holds `session: ULID`, `recorded: Int`, `resolved: Int` — the recorded working context against the live resolution.

Public: `restoreSession`, `recordedWorkingDirectory`, `RestoredSession`, `RestoredSession.ContextMismatch`, `SessionConfigurationRestorationReport` and its `MissingTool`, `SessionTreeRestorationError`, `TranscriptTreeError`. `restoreSessionTree` and `RestoredSessionTree` stay internal, as we asked.

## Three details that decide the implementation

**1. Check the cwd BEFORE restoring.** Router added `recordedWorkingDirectory(ofSession:recordingRoot:)` for us. It loads the tree and nothing else — no backend, no session, no write — and it is **synchronous `throws`**, so it needs no await. Call it first, compare against the resume `cwd`, and error on a mismatch. Do not restore and then reject; that builds a whole session in order to throw it away.

**2. A missing session raises `TranscriptTreeError.sessionNotFound`, NOT `SessionTreeRestorationError`.** Both are public, and `recordedWorkingDirectory` raises the same case, so the deleted-session path errors at the cheap pre-check. `SessionTreeRestorationError` covers restore-specific failures such as a non-root id. Catch the typed case; never match a message string.

**3. The instructions override applies to the NAMED ROOT only.** A recorded fork keeps its own recorded instructions. That suits us, because `restoreSession(id:)` releases those forks anyway and we never address a fork over ACP. A live fork taken later from the restored root does inherit the supplied string.

## Why the override exists, and the trap it closed

Without it, restore re-applies the recorded instructions and says nothing. Our §7.4 reassembles instructions from the current config layer, the AGENTS.md walk and the preloaded skill bodies, so that work would have gone nowhere and the session would have run on the stale recorded string.

Upstream's first implementation of the fix was itself broken in the same shape: it set a `RoutedSessionActor.instructions` property that no generation path reads, because the restore path calls `container.makeSession(transcript:tools:)`, which takes no instructions argument — the SDK reads them from the transcript's leading `.instructions` entry. Their review caught it and fixed it at the transcript seam rather than documenting it. **Do not assume a supplied value reached the model because a property holds it.** Assert on behavior.

## The divergence event

Supplying instructions that differ from the recorded ones appends one `TranscriptEvent` of kind `.divergence`, carrying a stable phrase plus both character counts, with neither body and no hash. `nil` or an identical string writes nothing. Nothing is added to the return value for it — the audience is whoever reads the committed transcript later, not the caller.

Assert it through `TranscriptEvent.kind == .divergence`, and pin the text against `RestoredSession.instructionsDivergencePhrase`, which upstream made public at their commit `6be2294`. Name the symbol; never copy the literal into our source. The phrase is the documented grep target for a repository of committed transcripts, so a saved grep breaks if it drifts — pinning the symbol is what makes that drift a compile error rather than a silent miss.

## The work

`session/resume(sessionId, cwd, mcpServers, additionalDirectories, replayFrom)`:

- `cwd` MUST equal the recorded original, checked with `recordedWorkingDirectory` before any restore. A mismatch gives an error, never a silent re-root.
- Reassemble our side from the recorded cwd: the config layer, the instructions, the tools and the confinement. Reconnect the config and client MCP servers. The client list is authoritative on each reconnect and is never persisted.
- Pass the freshly assembled instructions as `instructions:`. Pass the roster as `tools:`; Router matches by recorded name and we supply the instances.
- **Report `configurationReport.missingTools` to the client. Do not swallow it.** Resume is where our roster legitimately differs from the recording: `shell: false` newly set, an MCP server that failed to connect, a replaced `additionalDirectories` set, a deleted skill.
- `additionalDirectories` is authoritative and replaceable. A non-empty list is the complete new root set. Omitted or empty means no additional roots. Never inherit former roots. Persist the new ordered list to the index.
- Replay: `replayFrom: {"type": "start"}` replays before the response returns. Omitted or null means no replay. Replay sends whole-message upserts (`user_message`, `agent_message`, `agent_thought`) with the original `messageId` values, never `*_chunk`, so a client that saw chunks converges through §8.3's replace row. Replay reads the full recorded history; fold checkpoints are not messages and are not sent. Write the replay path with `ReplayFrom` as an inclusive cursor parameter.
- `ResumeSessionResponse` carries `configOptions`, from the same source as session/new.

- [x] cwd equality check through `recordedWorkingDirectory`, before restore
- [x] Composition reassembly and root-set replacement
- [x] `restoreSession(id:recordingRoot:instructions:tools:)` with fresh instructions
- [x] `missingTools` reported to the client
- [x] Cursor-shaped replay sending whole-message upserts
- [x] Deleted-session path catching `TranscriptTreeError.sessionNotFound`

**Unknown-id policy (plan.md §10.1, decided 2026-09-01).** `session/resume` with an unknown `sessionId` — a deleted session included — gives JSON-RPC invalid params (`-32602`) with the id in `data`. Map `TranscriptTreeError.sessionNotFound` to that error. A known, closed session resumes normally; that is what resume is for.

## Acceptance Criteria
- [x] `session/resume` on an unknown id gives `-32602` with the id in `data`
- [x] Record a scripted two-turn session, then resume with `replayFrom: start`: the collector receives whole-message upserts with the original messageIds, no chunks, before the resume response completes
- [x] Resume with a different cwd errors, and no session was constructed — assert the scripted loader was never asked for a backend
- [x] Resume after delete gives a clean protocol error, driven by catching `TranscriptTreeError.sessionNotFound`
- [x] Resume omitting `additionalDirectories` on a session that had extra roots rebuilds confinement with the cwd only, asserted because a file outside the cwd is now refused
- [x] A resumed session continues the conversation, and its next turn sees the earlier context
- [x] Resuming with `shell: false` newly set reports the missing shell verbs from `configurationReport`
- [x] **Resuming with changed instructions makes the MODEL see them** — assert through the scripted backend's received transcript, not through any property that holds the string
- [x] Resuming with changed instructions writes one `.divergence` event; resuming with unchanged or nil instructions writes none

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift` — harness, record-then-resume round trips in temp repos
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-02 21:41)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift:19` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.
