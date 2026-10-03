---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3zbdvv66azfsrfshmhb933c
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — blocked on upstream FoundationModelsACP ^k55fg8a (Unstable compaction types) and ^zj1wfec (engine keeps a compaction entry); not on main yet, and the owner decides when they run
    - next: when that session sends the commit and the final type names, move the pin and run /implement on this card
  timestamp: 2026-10-02T22:23:16.838651+00:00
- actor: claude-code
  id: 01m40vyjc25zpfhgz387q7whps
  text: |-
    Unblocked: FoundationModelsACP main 60854b6 has the unstable compaction and notice types and the engine support (^k55fg8a, ^zj1wfec).
    ```swift
    let update = Unstable.CompactionUpdate(compactionId: id, status: .inProgress /* later .completed / .failed / .cancelled */,
                                           summary: .value(blocks) /* or .unchanged */, error: .unchanged, meta: .unchanged)
    let wire = try SessionUpdate(Unstable.SessionUpdate.compactionUpdate(update))
    // send `wire` as a normal session/update, and apply it to the SessionMergeEngine
    ```
    - Stream the summary with `Unstable.SessionUpdate.compactionSummaryChunk(Unstable.CompactionSummaryChunk(compactionId:content:meta:))` after the in_progress update and before the terminal update.
    - Optional live message: `Unstable.SessionUpdate.notice(Unstable.Notice(severity: .info, title: ..., description: ...))`; the engine returns `Change.notice` and does not store or replay it.
    - The engine keeps the compaction as an entry `SessionEntry.ID.compaction(id)` at a fixed position; `transcriptUpdates` replays it with its final status and summary. Keep replaying from the engine, never the Router transcript.
    - Check the exact initializer labels in `Sources/FoundationModelsACP/Generated/Unstable.Models.generated.swift`.
    Start after ^56jbp35 (one implementer in this tree at a time); move the pin to 60854b6 or later first.
  timestamp: 2026-10-03T12:31:15.842152+00:00
- actor: claude-code
  id: 01m40z2ca49rada8z45e51f5ac
  text: |-
    Research (implement, picked up):
    - Router at the pinned revision gives NO "compaction started" event. `SessionEvent.compaction(CompactionResult)` is the only compaction event. It comes after an automatic compaction (proactive fold, reactive overflow retry, compaction yield) is done. A failure or a cancel of an automatic compaction throws out of the answer with no event and no compaction id. A shortfall comes as `CompactionResult.shortfall`.
    - Manual `/compact` (BuiltinCommands.compactReport) calls `RoutedSession.compact()`; it emits no SessionEvent. The agent can see the start, the result, the shortfall, a thrown failure and a CancellationError there.
    - Router gives the summary whole (`CompactionResult.summary: String?`), never in parts. Thus the summary goes on the completed update; no `compaction_summary_chunk`.
    - The single choke point is `RoutedACPAgent.historySink(for:connection:)`: it applies each update to the SessionMergeEngine of the session, then posts it. EventProjection.send is that sink. The `/compact` action has no sink today, so the builtin context binding needs one.
    - Plan: one `CompactionReporter` (Agent layer) makes and sends the `compaction_update` and the `usage_update`. Automatic: terminal update keyed by `result.id` (no in_progress, because Router shows no start). Manual: own ULID id, in_progress before `compact()`, then completed / failed (shortfall reason or error) / cancelled.
    - IntegrationTests/Package.resolved pins FoundationModelsACP 284e002; root pins 60854b6. Align it.
  timestamp: 2026-10-03T13:25:46.436338+00:00
- actor: claude-code
  id: 01m4100yxhczf2h8q8r7n26y9g
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsACPAgent/Agent/CompactionReporter.swift`: makes each UNSTABLE `compaction_update` through `SessionUpdate(Unstable.SessionUpdate.compactionUpdate(...))`. `reportStart` = in_progress; `reportEnd(with: result)` = completed with the summary as one text block, then `usage_update` (size = max(before, after), used = after); a shortfall = failed with `shortfallReason` (moved here from BuiltinCommands); `reportEnd(throwing:)` = cancelled for CancellationError, else failed with the error text. An encode failure asserts and logs.
    - EventProjection `.compaction(result)` (automatic) now calls `reportAutomaticCompaction` keyed by `result.id`. Behavior change: a shortfall no longer sends a `usage_update` (the meter did not move).
    - `/compact`: `BuiltinCommandContext.Binding.compactionReporter`; the agent makes a ULID compaction id, sends in_progress before `compact()`, then the terminal update. The streamed text report is unchanged.
    - Choke point: new `RoutedACPAgent.boundHistorySink(for:)` reads the bound connection at send time and delegates to `historySink(for:connection:)`, which applies to the SessionMergeEngine first. So session-history.json and a resume replay the compaction entry.
    - Tests: `CompactionReportTests` (8): automatic completed + usage; automatic shortfall failed, no usage; manual in_progress then completed + usage; manual shortfall failed with the reason; manual summarizer failure failed; cancel = cancelled; earlier messages keep id and content in the engine; new agent resumes from session-history.json and replays the compaction entry (completed, summary, same id) and the earlier messages. `EventProjectionTests.aCompactionSendsOneUsageUpdate...` renamed and updated: the kinds are now [unknown (the compaction_update), usageUpdate, stateUpdate].
    - plan.md: §7.4 replay bullet, §8.4 table row, §8.5 rewritten, §14.1 and §14.3 /compact lines.
    - IntegrationTests/Package.resolved (gitignored): FoundationModelsACP 284e002 -> 60854b6.
    - Discovery / gap: Router gives no start, failure or cancel event for an AUTOMATIC compaction. An automatic entry thus has only its terminal update, and an automatic failure or cancel shows only as the prompt stop reason. Filed ^fhwk6sn (#upstream) to ask Router for those events.
    - Process note: one plan.md edit was made with a python one-off through the shell (the files tool echo of plan.md is too large); the next agent should use the files tool edit op, which works (only its echo overflows).
  timestamp: 2026-10-03T13:42:28.529232+00:00
- actor: claude-code
  id: 01m410126dewf9y27y3g8p7nyv
  text: |-
    ### implement — changed
    - evidence: `swift build -c release` complete, 0 warnings, 0 errors; `swift test` 733 tests in 83 suites passed (1 known issue, the existing HarnessSmokeTests withKnownIssue); `swift build --package-path IntegrationTests --build-tests` complete (only the existing SwiftPM "missing creator for mutated node" mlx bundle note). Files: Sources/FoundationModelsACPAgent/Agent/CompactionReporter.swift (new), Agent/EventProjection.swift, Agent/SessionHistory.swift, Agent/SessionSetup.swift, Commands/BuiltinCommands.swift, Tests/FoundationModelsACPAgentTests/CompactionReportTests.swift (new), Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, plan.md, IntegrationTests/Package.resolved (gitignored).
    - next: /review
  timestamp: 2026-10-03T13:42:31.885104+00:00
- actor: claude-code
  id: 01m410cf39ezerkwbys6cry9e7
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (2ece010). 0 findings, 0 confirmed, 0 refuted. 7 files attempted, 0 failed. Not reviewed: 4 .kanban files (from .reviewignore) and plan.md (no validator matches this file).
    - next: none. The task is in done.
  timestamp: 2026-10-03T13:48:45.545405+00:00
- actor: claude-code
  id: 01m410cqq2w3rbdyndvy6qhc13
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 9 files (CompactionReporter, history sink, manual and automatic paths, 8 tests, plan.md)
    - test: green — swift test 733 tests in 83 suites; release build 0 warnings; IntegrationTests build (reported by implement)
    - commit: 2ece010
    - review: clean — 0 findings
    - open upstream: automatic start / failure / cancel events, tracked on ^fhwk6sn (Router ^k1gepqc)
  timestamp: 2026-10-03T13:48:54.370064+00:00
position_column: done
position_ordinal: ff9480
title: Report each Router compaction as an ACP compaction entry, and keep the full ACP history across a compaction
---
## Why

Owner decision (relayed by the FoundationModelsACP session, 2026-10-02): a Router compaction changes only the model context. The ACP transcript keeps the full history, and a compaction shows as one more entry.

## Rules

1. When Router compacts (manual `/compact` or the auto-compaction budget), the agent removes or rewrites nothing in the ACP history. Earlier messages keep their IDs and content in the `SessionMergeEngine`.
2. The retained history for `session/resume` is the full engine transcript (`transcriptUpdates` / `stateUpdates`), never the Router transcript or journal (after a fold it holds a summary, with no ACP IDs). Card ^hkr6ykz sets up this replay.
3. Report each compaction with the upstream UNSTABLE ACP updates:
   - `compaction_update`: upsert by `compactionId`; `status` in_progress, then completed / failed / cancelled; the retained `summary: [ContentBlock]`; `error` on failure.
   - optional `compaction_summary_chunk` to stream the summary.
   - optional `notice` for a short live message (not stored, not replayed).
   - a `usage_update` with the new `used` value.
4. FoundationModelsACP gives only the types; it does not depend on Router.

## Blocked until

FoundationModelsACP pushes ^k55fg8a (the types in an `Unstable` namespace: `Unstable.SessionUpdate`, `CompactionUpdate`, `CompactionSummaryChunk`, `CompactionStatus`, `Notice`) and ^zj1wfec (the engine keeps a compaction as an entry and replays it). That session sends the commit and the final names. Do not start before then.

## What to do (when unblocked)

- Map Router's compaction events (`compactionStarted` / `compacted` / the shortfall / the failure, see `EventProjection` and `BuiltinCommands` `/compact`) to `compaction_update` with one `compactionId` per compaction, and stream the summary if Router gives it in parts.
- Send a `usage_update` with the new context use after the compaction.
- Apply each of these updates to the session engine, so a resume replays the compaction entry.
- Tests: a manual `/compact` gives in_progress then completed with the summary; a shortfall gives failed with the reason; earlier messages keep their IDs and content in the engine after the compaction; a resume replays the compaction entry. #upstream