---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4102b1yzs8y03jr5t0y2419
  text: Carded on the FoundationModelsRouter board as ^k1gepqc (2026-10-03), written with `sah tool kanban` because no Router session was running. It asks for `compactionStarted(id, reason)` before an automatic compaction and `compactionFailed(id, .failed(error) | .cancelled)`, with the same id as `CompactionResult.id`. Blocked until Router pushes it.
  timestamp: 2026-10-03T13:43:13.726024+00:00
- actor: claude-code
  id: 01m444fhwp65ppt75zq5ht1fdj
  text: |-
    Unblocked: Router ^k1gepqc is on main at 63ed8fb8.
    - `SessionEvent.compactionStarted(CompactionStart{id, reason})`, then `SessionEvent.compaction(CompactionResult)` or `SessionEvent.compactionFailed(CompactionFailure{id, reason, outcome: .cancelled | .failed(String)})`. All three carry the same id.
    - `CompactionReason`: `.triggerReached`, `.contextOverflow`, `.toolResultYield`, `.outputCeilingStop`.
    - A manual `compact()` sends no compaction event, so the agent's own manual updates get no duplicates.
    Do: move the Router pin; map compactionStarted -> `in_progress`, compactionFailed -> `failed` (with the string) / `cancelled`, keyed by the id; add tests in CompactionReportTests (automatic start then completed; automatic failure; automatic cancel; the history and a resume hold the final status); update plan.md §8.5 (remove the limit).
  timestamp: 2026-10-04T18:58:04.310533+00:00
- actor: claude-code
  id: 01m444nbctarxnzatyt6g1h5qc
  text: |-
    Research (implement):
    - Package.resolved pins Router at 63ed8fb8. IntegrationTests/Package.resolved (gitignored) lags at c5ebd440; align it.
    - Router `performAutoCompaction` sends `compactionStarted(CompactionStart{id, reason})`, then `compaction(result)` (the same id through `withId`) or `compactionFailed(CompactionFailure{id, reason, outcome})`. The outcome is `.cancelled` when the work is cancelled or the error is a `CancellationError`, else `.failed(String(describing: error))`.
    - The proactive fold (`.triggerReached`) runs only when `usageState.measuredTokens` is set, thus only from the second prompt of a session.
    - The one total switch over `SessionEvent` in Sources is `EventProjection.project(_:)`; it has `@unknown default`, so the build is green before the change and the new cases fall to a debug log. No test switches over `SessionEvent`.
    - `CompactionReporter` already has `reportStart(of:)` and the `cancelled` / `failed` updates. The projection `send` is the history sink of the session, thus `session-history.json` and a resume hold the upserted final status.
  timestamp: 2026-10-04T19:01:14.266944+00:00
- actor: claude-code
  id: 01m4463qcp7hm5v5crg73dq09x
  text: |-
    Implementation landed (TDD: the four new tests were RED first, for the expected reason).
    - Effect of the pin move (Router 63ed8fb8): the build stayed green, but `EventProjection.project(_:)` gave the compiler warning "switch must be exhaustive", because `compactionStarted` and `compactionFailed` fell to `@unknown default`. The two new cases remove that warning. No other total switch over `SessionEvent` is in Sources or Tests.
    - `CompactionReporter`: `reportAutomaticStart(_:)` (in_progress, keyed by `CompactionStart.id`) and `reportAutomaticFailure(_:)` (`.cancelled` -> cancelled, `.failed(String)` -> failed with that text). `reportEnd(of:throwing:)` and the new path share one private `reportCancel(of:)`. The completed path did not change.
    - `EventProjection`: `projectCompaction(_:)` is now a private `compactionReporter` property, and the three cases call it. All updates go through `send`, the history sink.
    - Tests (CompactionReportTests): automatic start then completed; automatic failure; automatic cancel; a resume replays the final status (`failed` with the text) of an automatic compaction that went through the bound history sink of a live session. The two resume tests share a new `closeAndResume(_:label:)` helper.
    - Why the resume test uses synthetic events and not a real proactive fold: Router folds only when `usageState.measuredTokens` reaches the trigger, and `CompactionStubBackend` reports a constant usage of (1, 1), so its measured context never grows.
    - plan.md §8.5: the "Automatic" bullet now gives the start and the terminal events. The old limit is removed.
    - IntegrationTests/Package.resolved (gitignored): Router pin moved from c5ebd440 to 63ed8fb8.
    - A parallel `swift test` fails 4 tests on the 60 s time limit. HEAD with no source change fails the same 4 tests in the same way. The machine load average was 30 to 62 on 32 cores (sourcekit-lsp index builds). `swift test --no-parallel` passes all 737 tests. Filed ^vjaka1g.
  timestamp: 2026-10-04T19:26:33.878706+00:00
- actor: claude-code
  id: 01m4463x8yzjn6tvwf5mbk93q0
  text: |-
    ### implement — changed
    - evidence: 4 tracked files — Sources/FoundationModelsACPAgent/Agent/CompactionReporter.swift, Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/CompactionReportTests.swift (+4 tests, 12 in the suite), plan.md §8.5; plus the gitignored IntegrationTests/Package.resolved (Router c5ebd440 -> 63ed8fb8). `swift build -c release`: complete, 0 warnings from this package (only the third-party mlx Metal header warnings of the checkout). `swift test --filter CompactionReportTests`: 12 passed. `swift test --no-parallel`: 737 tests in 83 suites passed (1 known issue, as at HEAD). Parallel `swift test`: 737 tests, 4 failed on the 60 s time limit (SessionResumeTests x2, CompactionReportTests.aResumeReplaysTheCompactionEntryAndTheEarlierMessages, BuiltinCommandsTests.noBuiltinInvokesTheModelBackend); HEAD with no source change fails the same 4 (733 tests). Filed ^vjaka1g. `swift build --package-path IntegrationTests --build-tests`: complete.
    - next: /review
  timestamp: 2026-10-04T19:26:39.902047+00:00
position_column: doing
position_ordinal: '80'
title: 'Report upstream: Router gives no start, failure or cancel event for an automatic compaction'
---
## Why

Card ^e8hafh0 reports each Router compaction as one ACP `compaction_update` entry. For a manual `/compact` the agent calls `compact()` itself, so it sends `in_progress`, then `completed` / `failed` / `cancelled`. For an automatic compaction (the proactive fold, the overflow retry, the compaction yield) Router gives only `SessionEvent.compaction(CompactionResult)`, after the compaction is done. Thus:

- the automatic entry has no `in_progress` update; its first update is the terminal one;
- a failure or a cancel of an automatic compaction throws out of the answer with no event and no compaction id, so the client sees no entry for it, only the stop reason of the prompt.

## What to do

- Ask the FoundationModelsRouter session for a `compactionStarted(id:)` event before an automatic compaction runs, and a terminal event (or an error that names the compaction id) when it fails or is cancelled. Do not change Router from this repository.
- When Router ships it: map the start to `in_progress` and the failure / cancel to `failed` / `cancelled` in `CompactionReporter`, and add a test in `CompactionReportTests`.
- Update plan.md §8.5 (the "Automatic" bullet). #upstream