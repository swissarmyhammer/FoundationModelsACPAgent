---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tj7b79twk985hw72wcfba1
  text: |-
    Reproduced on aed2a00: `swift test --skip-build --filter AgentTranscriptSearcherTests --maximum-repetitions 30` gave 6 failed expectations (parallel), and 6 with `--no-parallel`. A temporary print in `TranscriptSearchApplier.apply` (removed) shows two background writers:

    1. The reconcile at launch (`startReconcile`, a task with `.background` priority). When the task reads the project store after `session/new` registered the fixture folder, it puts `.reconcile(<fixture folder>)` in the queue late. The fixture sessions have a record but no history file, so the reconcile removes their chunks. Each failure with empty pages (`first.nextCursor` nil, `results.count == 0`) had a `reconcile` of its own fixture folder between the index of the chunks and the read.
    2. The events of the session directory (`started`, `factsChanged` with the D199 name "default-2"). The reader task gives them to the queue late, and `update(session:metadata:)` replaces the session item. Thus one page shows the snippet "default-2" and the other page shows "".

    `waitUntilApplied()` does not cover the reconcile at launch: the task can put its change in the queue after the mark. This is a gap in the contract of `waitUntilApplied()` ("each change that the object got before this call") and of the shutdown, so the fix makes `waitUntilApplied()` wait for the reconcile at launch to put its folders in the queue. The test then (a) waits on the queue before it indexes, (b) adds a tag to each session and waits until the index holds the tagged session item, so each earlier directory event is applied, and (c) waits on the queue before each read.
  timestamp: 2026-11-19T18:48:38.377288+00:00
- actor: claude-code
  id: 01m7tjkyn3z4kmdweygt9fe9ww
  text: |-
    ### implement — changed
    - evidence: commit 5b71964. Files: Sources/FoundationModelsACPAgent/Search/TranscriptSearchUpdates.swift (waitUntilApplied() also waits for the task of the reconcile at launch), Tests/FoundationModelsACPAgentTests/TranscriptSearchUpdatesTests.swift (new test theWaitIncludesTheReconcileAtLaunch: RED before the fix, GREEN after), Tests/FoundationModelsACPAgentTests/AgentTranscriptSearcherTests.swift (indexSettled + settle helpers, a wait on the queue before each read). Loop before: 6 failed expectations in 30 repetitions (parallel), 6 with --no-parallel. Loop after: `swift test --skip-build --filter AgentTranscriptSearcherTests --maximum-repetitions 30` = 0 issues in 150 test runs; `--no-parallel` loop over the three search update suites = 0 issues in 23 tests x 30.
    - Note: the shutdown of the agent now also waits for the reconcile at launch, so a quit during launch keeps the reconciled items.
    - next: review
  timestamp: 2026-11-19T18:55:31.491460+00:00
- actor: claude-code
  id: 01m7tkgvkgprfh30b6r8b2vkf9
  text: |-
    ### review — findings
    - evidence: review sha 5b71964~1..5b71964: 2 findings, 2 confirmed, 0 refuted, 7 attempted, 0 failed. Tests/FoundationModelsACPAgentTests/AgentTranscriptSearcherTests.swift:84, Tests/FoundationModelsACPAgentTests/AgentTranscriptSearcherTests.swift:87 (reuse/reuse).
    - next: Move `pollLimit` and `pollInterval` to one shared test helper and use it from AgentTranscriptSearcherTests and TranscriptSearchUpdatesTests. Then review again.
  timestamp: 2026-11-19T19:11:18.640586+00:00
- actor: claude-code
  id: 01m7tkt5pzdd8d7bja5c6pz2qp
  text: |-
    ### finish iteration 2 — implement and test
    - implement: changed — Tests/FoundationModelsACPAgentTestSupport/IndexPoll.swift (new: `IndexPoll.limit`, `IndexPoll.interval`, `pollIndexUntil(_:)`); the two private copies of `pollLimit` and `pollInterval` are removed from AgentTranscriptSearcherTests and TranscriptSearchUpdatesTests, which now call `pollIndexUntil`. Both findings are checked.
    - test: green — swift build --build-tests "Build complete!", 0 compiler warnings; swift test --skip-build: 2637 tests in 277 suites passed, 1 known issue (intended).
  timestamp: 2026-11-19T19:16:23.903193+00:00
- actor: claude-code
  id: 01m7tkyqgaxz6j3kckqzam80qr
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (2b0a468): 1 finding (1 confirmed, 1 refuted, 7 attempted, 0 failed). Tests/FoundationModelsACPAgentTestSupport/IndexPoll.swift:10 `code-hygiene/magic-numbers-swift`.
    - next: Replace the magic numbers in IndexPoll.swift with named constants. Remove this cause from the full file. Then check the item and run the review again.
  timestamp: 2026-11-19T19:18:53.194496+00:00
- actor: claude-code
  id: 01m7tm85aycjq7kg52wg62gv5e
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (e6ce9e3). 0 findings, 0 confirmed, 0 refuted. 7 engine tasks attempted, 0 failed. 1 file reviewed (Tests/FoundationModelsACPAgentTestSupport/IndexPoll.swift). 2 .kanban files not reviewed (ignore rule). All prior findings are checked.
    - next: none. The task is in done.
  timestamp: 2026-11-19T19:24:02.270758+00:00
position_column: done
position_ordinal: ffffffa780
title: 'AgentTranscriptSearcherTests is flaky: the background search updates of the fixture agent change the index between two reads'
---
Found during ^w0dheny (2026-11-19). The flake is there on HEAD 7ba6a38 with no change of the search code.

Evidence: `swift test --skip-build --filter AgentTranscriptSearcherTests --maximum-repetitions 30` on HEAD gave 10 failed expectations in 30 runs: `theAfterCursorOfTheFieldGivesTheNextPage` (first.nextCursor is nil; first.results + second.results != whole.results), `theSearchSessionsFieldGivesTheSessionsAndHitsOfTheTool` (results.count, snippets), `theSessionsToolSearchesWithTheSearcherOfTheAgent` (answer has no "lives on an island.").

Cause (from the failure output): the fixture indexes its chunks with `indexWord` directly in `agent.transcriptSearchIndex`, but the agent of the fixture also runs `TranscriptSearchUpdates` in the background. A directory event of a new session (the name "default-2" from D199 naming, the history of the prompt) replaces the items of the session in the index while the test reads its pages. Thus two reads of the same query can see two states of the index: a session item with the snippet "default-2" comes in one page and not in the other, and the indexed chunk "The quokka lives on an island." can be replaced by the history of the session.

Fix direction: the test waits until the background updates of the fixture are idle before it indexes its chunks and reads its pages, or it indexes into an index that no background update writes. Do not weaken the assertions. #test #flaky #search

## Review Findings (2026-11-19 13:08)

> Scope: `review sha 5b71964~1..5b71964` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 0 not reviewed.

- [x] `Tests/FoundationModelsACPAgentTests/AgentTranscriptSearcherTests.swift:84` `reuse/reuse` — The new `pollLimit` constant redefines a constant that already exists in `TranscriptSearchUpdatesTests` with the same value (3600) and the same doc comment. Two copies of the same wait tuning can drift apart, so one fix would need two edits. Move `pollLimit` and `pollInterval` to one shared internal test helper (for example, beside `pollUntil`) and reference that single definition from both test suites. Do not keep a private copy in each suite.
- [x] `Tests/FoundationModelsACPAgentTests/AgentTranscriptSearcherTests.swift:87` `reuse/reuse` — The new `pollInterval` constant duplicates the existing `pollInterval` in `TranscriptSearchUpdatesTests` with the same value (`Duration.milliseconds(25)`) and the same comment. Share one definition with `pollLimit` from a common test helper, as described for line 84.

## Review Findings (2026-11-19 13:16)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsACPAgentTestSupport/IndexPoll.swift:10` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
