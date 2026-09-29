---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39t4d8mxc7zxmgnavmec44t
  text: |-
    Scope added (from the Router session, 2026-09-24): Router card ^1hcwaqy, not committed yet, brings two more enum cases and a host option. Handle them in this card.

    ## Two more cases

    - `FinishReason.repeatedLines`: the call stopped because it repeated itself. Map it to a stop reason that says so (proposal: `_repeated`), beside `_truncated` and the value for `.endedInsideReasoning`, in `PromptTurn.stopReason(for:)` and in `ExitCode.swift`.
    - `SessionEvent.repetitionStopped(RepetitionStop)`: the detector stopped a call. `EventProjection` has an `@unknown default` arm, thus it compiles, but the event must not fall into it silently. Log it with its numbers, as the `_truncated` line does, and decide whether it reaches the wire.

    A `switch` with no default over either enum does not compile until it handles the new case. Check `Sources` and `Tests` when the Router commit lands.

    ## The host option

    `RepetitionDetection` (isEnabled, windowTokens, minimumLineLength, recoveriesPerTurn; defaults true, 2,048, 20, 2 — the owner approved these as configurable starting points). It passes through `SessionConfiguration.repetitionDetection`, or a new last parameter `repetitionDetection:` of `makeSession(...)`.

    Expose it in `config.yaml`, for example under `compaction:` or a new `repetition:` section, with the four keys and Router's defaults when absent, and pass it in `makeBudgetedSession`. Add it to `config show`, to the codec tests, and to the bench README.
  timestamp: 2026-09-24T13:36:58.132988+00:00
- actor: claude-code
  id: 01m39zhvfdec6c3x0aa8f5xqrw
  text: |-
    Scope added (from the Router session, 2026-09-24): Router cb631e6 and 94a5723 (^gg49g5e there) add the transcript event kind `repeatedPartRemoval`. A session that had a repetition stop writes it; a restore reads it, so that the repeated part stays out of the restored render.

    ## What it does here

    - `SessionResume.update(for:)` switches over `TranscriptEvent.Kind` with no default, thus the build breaks until it names the new case. It is bookkeeping, not a message: add it to the arm that returns `nil`, beside `.generationCall`, with a comment.
    - Check every other `switch` over `TranscriptEvent.Kind` in `Sources` and `Tests` (`TerminalStream`, `SessionResumeTests`) the same way.
    - Test: a session resumed from a journal that holds a `repeatedPartRemoval` line replays no message for it, and replays the messages around it.

    Decision of the owner (2026-09-24): no compatibility work. Journals from older builds are not a concern of this card.
  timestamp: 2026-09-24T15:11:41.549533+00:00
- actor: claude-code
  id: 01m3nhkvr14g0pkgv9hs9v61kz
  text: |-
    Blocker (2026-09-28): the pinned Router cannot supply the new case.

    - The local `Package.resolved` pins FoundationModelsRouter to bbad3ce. The current family main branches break the build here, thus the pin stays. The adoption of the newer Router API is card ^tz867gz, which is blocked.
    - In `.build/checkouts/FoundationModelsRouter` (HEAD bbad3ce), `FinishReason` has only `completed` and `maxTokens`. A search for `endedInsideReasoning` finds no match.
    - `git merge-base --is-ancestor b3b3d72 HEAD` returns 1: Router b3b3d72 is not in the pinned revision. The cases `repeatedLines`, `SessionEvent.repetitionStopped`, `RepetitionDetection` and the transcript kind `repeatedPartRemoval` from the added scope are also after the pin.

    No file changed. This card can continue when ^tz867gz moves the Router pin to a revision that holds b3b3d72.

    ### implement — stuck
    - evidence: pinned Router bbad3ce has no `FinishReason.endedInsideReasoning`; b3b3d72 is not an ancestor of bbad3ce. No file changed.
    - next: finish ^tz867gz (Router pin adoption), then do this card again.
  timestamp: 2026-09-29T02:59:00.481443+00:00
- actor: claude-code
  id: 01m3nhm8wkhvsy7te9t6h8qpe9
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The pinned Router bbad3ce has no FinishReason.endedInsideReasoning (it came in Router b3b3d72).
    - test, commit, review: not run
    - next: this task waits for ^tz867gz (adopt the newer Router).
  timestamp: 2026-09-29T02:59:13.939596+00:00
- actor: claude-code
  id: 01m3qd00f4cbvq4fj0k4hsqpca
  text: |-
    Picked up again (2026-09-29). Research:

    - The pinned Router (Package.resolved c49e453) now has `FinishReason.endedInsideReasoning` and `FinishReason.repeatedLines`, `SessionEvent.repetitionStopped(RepetitionStop)`, `RepetitionDetection` (five values now: isEnabled, windowTokens, minimumLineLength, recoveriesPerAnswer, passTokenLimit) and `TranscriptEvent.Kind.repeatedPartRemoval`. The blocker of 2026-09-28 is gone.
    - Code names now: `PromptExecution` (was `PromptTurn`), `PromptStateOwner`. `EventProjection` keeps `lastFinishReason` from `.submissionEnded`; `endedAtTokenCeiling` reads only `.maxTokens`.
    - `SessionResume.update(for:)` already puts `.repeatedPartRemoval` in the arm that returns `nil`, beside `.generationCall`. That part of the added scope is done by an earlier card; I add only the replay test if it is missing.
    - `repetitionStopped` falls into a shared `debug` arm in `EventProjection` with `answered` and others.
    - Exit code: `_truncated` is `StopReason.unknown`, and `AgentExitCode(stopReason:)` maps `.unknown` to `.error` (exit 1). The new values take the same row: exit 1. No new arm in the switch; a test holds the mapping.
    - acp-client lives in the FoundationModelsACPClient repository. Its `ExitCode.swift` maps `.unknown` in general, and it names no `_truncated`. The `acp-agent` `EventLineWriter` prints the wire value in general. No change there.
    - Docs that name `_truncated`: plan.md §8.2, bench/README.md, bench/swebench_acp.py module text.

    Decisions: `_ended_in_reasoning` for `.endedInsideReasoning` (owner decision); `_repeated` for `.repeatedLines`; both exit 1. `repetitionStopped` gets its own `notice` log line with the model and the report text, and no wire message. The host option becomes a new `repetition:` section in `config.yaml` with Router's five property names as keys and Router's defaults.
  timestamp: 2026-09-29T20:16:44.516045+00:00
- actor: claude-code
  id: 01m3qdjnv23148xen49ar151h4
  text: |-
    Implementation landed (not committed).

    Stop reasons:
    - `PromptStop` has two new cases, `endedInReasoning` and `repeated`. `PromptExecution.stopReason(for:)` maps them to `_ended_in_reasoning` (`endedInReasoningStopReasonValue`) and `_repeated` (`repeatedStopReasonValue`).
    - `PromptExecution.cutStop(for:)` is a total switch over `FinishReason` with no `default`: `.completed` -> nil, `.maxTokens` -> `.truncated`, `.endedInsideReasoning` -> `.endedInReasoning`, `.repeatedLines` -> `.repeated`. A new Router finish reason stops the build there.
    - `EventProjection.endedAtTokenCeiling` is removed; `lastFinishReason` is now `private(set)` and `drive` reads it through `cutStop(for:)`.
    - The usage log line is now `report(cut:usage:)`. It names the wire value of the cut stop, thus all three cut stops log `tokensIn`, `tokensOut` and `contextFill`.

    Exit code decision: `_truncated` is `StopReason.unknown` and `AgentExitCode(stopReason:)` maps `.unknown` to `.error`, exit 1. `_ended_in_reasoning` and `_repeated` take the same row, exit 1. The switch did not change (its source-shape test holds six arms). The doc comment of `init(stopReason:)` now names each extension value and its exit 1, and `ExitCodeTests.aCutPromptStopReasonExitsError` holds the three values.

    acp-client (FoundationModelsACPClient repo) maps `.unknown` in general and names no `_truncated`; `EventLineWriter` prints the wire value in general. No change there.

    Added scope:
    - `repetitionStopped` has its own arm in `EventProjection` and a `notice` log line with the model and `RepetitionStop.description` (counts and settings). No wire message.
    - New `repetition:` config section (`Configuration/RepetitionConfiguration.swift`): keys `isEnabled`, `windowTokens`, `minimumLineLength`, `recoveriesPerAnswer`, `passTokenLimit` (Router added `passTokenLimit` after the card comment, so five keys, not four), Router defaults when absent. It is key-checked, in `config show` (ConfigurationYAML section order and comment), and `makeBudgetedSession` takes it (new parameter `repetition:`; `session/new` and the model-slot switch pass it).
    - `repeatedPartRemoval`: `SessionResume` already handled it; the new test `replaySendsNoMessageForARepeatedPartRemovalLine` puts a real-shaped line in a journal and proves the replay.

    Docs: plan.md §2.4 (schema), §8.2 (five extension values), §8.4 table (repetitionStopped row); bench/README.md (stop reason table, `repetition:` keys table); bench/swebench_acp.py module text.

    Note for the next agent: card ^kfqvqqb (OTel 3, in doing) replaces os.Logger in PromptTurn/PromptExecution. The two cards touch the same log calls in `PromptExecution.swift` and `EventProjection.swift`; expect a merge there.
  timestamp: 2026-09-29T20:26:56.226767+00:00
- actor: claude-code
  id: 01m3qdjv3byzqp3mdfweq35e3h
  text: |-
    ### implement — changed
    - evidence: 18 files (17 changed, 1 new). Sources: PromptExecution.swift, EventProjection.swift, SessionSetup.swift, ConfigOptions.swift, AgentConfiguration.swift, ConfigurationYAML.swift, RepetitionConfiguration.swift (new), acp-agent/ExitCode.swift. Tests: PromptExecutionTests, ExitCodeTests, ConfigurationLoaderTests, ConfigShowTests, SessionSetupTests, SessionResumeTests, SkillOutputProtectionTests. Docs: plan.md, bench/README.md, bench/swebench_acp.py. `swift test`: 624 tests in 70 suites passed (1 known issue, from before), no compiler warning (only the swift-build notice "missing creator for mutated node" for the mlx bundle, from before). `swift build --build-tests` in IntegrationTests: complete, no warning. bench unittest: 208 OK.
    - next: /review
  timestamp: 2026-09-29T20:27:01.611020+00:00
- actor: claude-code
  id: 01m3qedebxcpbhdvd0w9n4gt4q
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (66bfd3c); 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift:450 (completeness/inverse-operation-coverage)
    - next: add a test that runs a prompt with finish reason `.repeatedLines` and makes sure that the session records a `repeatedPartRemoval` event with the correct text and structure. The task stays in review.
  timestamp: 2026-09-29T20:41:33.309323+00:00
- actor: claude-code
  id: 01m3qedtct82qrssk4xhkv5kyn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 18 files (PromptExecution.swift, EventProjection.swift, RepetitionConfiguration.swift new, ExitCode.swift, config files, 7 test files, plan.md, bench docs)
    - test: green — swift test 624 tests pass; IntegrationTests build ok
    - commit: 66bfd3c
    - review: findings — Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift:450
  timestamp: 2026-09-29T20:41:45.626420+00:00
- actor: claude-code
  id: 01m3qf5ftmmpn9860ce300dazv
  text: |-
    Review finding SessionResumeTests.swift:450 (completeness/inverse-operation-coverage) is corrected (2026-09-29).

    Who writes the entry: Router, not this repository. `RoutedSessionActorRepetitionWatch.recordRepeatedPartRemoval` writes the `repeatedPartRemoval` event after a repetition stop. The watch reads the public `LanguageModelSessionBackend.transcriptUpdates()` while a call is in flight. `ScriptedSessionBackend` kept the protocol default (a stream that finishes at once), so Router never watched a scripted call. The tool-call check path (`RepetitionCheckedTool`) is internal to Router's live loader, so the test support cannot use it.

    What changed (test code only, no production code):
    - `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`: new step `ScriptedPassStep.reasoning(String)`. It makes one `.reasoning` entry for each pass, with a stable id, and makes its text longer. `ScriptedSessionBackend` now implements `transcriptUpdates()`: it gives the entries at once and after each change (newest value only). All transcript changes go through one `changeTranscript` helper that feeds the open streams. Router's own detector then fires on scripted text. No Router logic is copied.
    - `PromptExecutionTests.aRepetitionStopRecordsARepeatedPartRemovalThatAResumeReplays`: `repetition:` config with `windowTokens: 200` and `recoveriesPerAnswer: 0`; a script with one new line, the repeated lines, and `.hold`. It asserts the idle stop reason `_repeated`, a `repeatedPartRemoval` event in the journal (Poll.until) with Router's text and a structure segment under `FoundationModelsRouter.RepeatedPartRemovalSegment` whose one cut keeps the UTF-8 length of the new lines, and a resume with `replayFrom` start that replays the recorded messages and no message for the cut. The test runs in 0.4 s.
    - `Tests/FoundationModelsACPAgentTests/Support/ReplayedMessage.swift` (new): the replay readers moved out of SessionResumeTests, so both suites share them. `ResumeSessionFixture` now holds Router's schema name and text prefix, which SessionResumeTests used as private constants.

    What did not work: asserting the key of the cut against the recorded reasoning entry id. `TranscriptEntryPayload.entryId` is internal to Router, so the test checks the one kept length only.

    RED: without `transcriptUpdates()` the watch never fired; the prompt held until the waits failed (no idle, no journal event). GREEN after the stream.
  timestamp: 2026-09-29T20:54:41.236180+00:00
- actor: claude-code
  id: 01m3qf5jc5bk2fnjaka3e4zdpq
  text: |-
    ### implement — changed
    - evidence: 5 files (1 new). Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift, Tests/FoundationModelsACPAgentTests/PromptExecutionTests.swift, Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift, Tests/FoundationModelsACPAgentTests/Support/ResumeSessionFixture.swift, Tests/FoundationModelsACPAgentTests/Support/ReplayedMessage.swift (new). `swift test`: 625 tests in 70 suites passed (1 known issue, from before); no compiler warning (only the swift-build notice "missing creator for mutated node" for the mlx bundle, from before). Finding SessionResumeTests.swift:450 checked. Not committed.
    - next: /review
  timestamp: 2026-09-29T20:54:43.845570+00:00
position_column: doing
position_ordinal: '8180'
title: Map Router's endedInsideReasoning finish reason to an honest ACP stop reason
---
## What changed in Router

Router b3b3d72 (card ^gfxd7av there) adds `FinishReason.endedInsideReasoning`: the output of a generate call ended inside the reasoning, below the ceiling. `.maxTokens` now means only that the call reached its ceiling. Router does not compact after the new case and does not send its ceiling continuation prompt.

## The gap here

`EventProjection.endedAtTokenCeiling` reads `lastFinishReason == .maxTokens`, and `PromptTurn` then ends a completed turn with `_truncated`. No `switch` over `FinishReason` exists, thus the build does not break. But a turn whose last call ends with `.endedInsideReasoning` now reports a plain `end_turn`: a cut turn reads as a finished one.

## What to do

1. Give the new case its own ACP stop reason. Proposal: a new extension value, `_ended_in_reasoning`, beside `_truncated`, so a client and the bench record can tell "reasoned until it stopped, with no answer" from "reached the output ceiling". Decide the name in the card.
2. Map it in `PromptTurn.stopReason(for:)`, and in the exit code table of `acp-agent` (`ExitCode.swift`), as `_truncated` is mapped.
3. Log it with the usage numbers, as the `_truncated` log line does.
4. Tests: a scripted turn whose last usage report carries `.endedInsideReasoning` ends with the new stop reason, and one with `.maxTokens` still ends with `_truncated`.
5. The bench README table of stop reasons names the new value.

Depends on Router b3b3d72 being on Router main.

#upstream

## Review Findings (2026-09-29 15:29)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 16 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `bench/README.md` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift:450` `completeness/inverse-operation-coverage` — Test covers reading/replaying `repeatedPartRemoval` journal events (via manually inserted events) but provides no test that such events are automatically written when a prompt stops with `repeatedLines` finish reason. The helpers `insertRepeatedPartRemoval`, `repeatedPartRemovalLine`, and `journalKind` are used to *construct* test data, not to verify automatic creation by the production code. Add a test in PromptExecutionTests that runs a prompt with `finishReason: .repeatedLines` (or actual repetition detection) and verifies the session's recorded events include a `repeatedPartRemoval` entry with the expected text and structure. This completes the round-trip: creation (write) and consumption (read).
