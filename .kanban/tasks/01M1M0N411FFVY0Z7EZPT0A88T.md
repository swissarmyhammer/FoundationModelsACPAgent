---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1m8sw5g6v67m9k711f5fd0r
  text: |-
    Picked up. Research of the projection is complete. The paths on the card are stale: card ^7srzb02 moved the whole `Evaluations/` directory into the nested `IntegrationTests` package, so the file to change is `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Evaluations/PythonCLIGraders.swift`.

    ## What the projection promises, read from the code

    `FoundationModelsRouter/Session/RoutedSessionActorRecording.swift` `emitSessionEvents(for:dispatchedToolCallIds:completedToolCallIds:onEvent:)` is the decisive function:

    - For each recorded `.toolCalls` entry, for EACH call in it, Router emits one `toolCall(id:name:argumentsJSON:)` and one `toolStatus(.running)`.
    - For each recorded `.toolOutput` entry, Router emits exactly one `toolStatus(.completed)`, paired to a call id by `ToolCallOutputPairing`.
    - After the diff, every dispatched id with no output gets `toolStatus(.failed)`. `ToolCallStatus.failed` means "the turn ended with no matching `.toolOutput` recorded for this call".

    `EventProjection.projectToolCall(id:name:argumentsJSON:)` sends one creating `tool_call_update` per `toolCall` event, carrying `title: name`. `ACPSessionState.toolCalls` is a dictionary keyed by tool-call id, so the client holds one entry per id.

    `TerminalStream.project(_:)` maps each shell run: `.output` becomes one `terminal_output_chunk`, `.gap` becomes one `terminal_update`, and `.completed` becomes one `terminal_update` carrying `exitStatus`. So EVERY completed shell run puts at least one counted notification on the wire.

    ## What this rules out

    The existing field `transcriptRunCodeSnippets` counts EVENTS, not calls: `runCodeSnippets(in:)` returns one JSON text per `.toolCalls` event, and one such entry can hold several calls (`TranscriptEntryPayload.toolCalls` is an array). So neither `snippets.count <= completedRunCodeCallCount` nor the reverse is guaranteed:
    - a batch of 3 parallel runCode calls in one entry gives 1 snippet but 3 wire calls;
    - a call with no `.toolOutput` gives 1 snippet but 0 completed wire calls.

    A count comparison for the runCode pair is therefore impossible with the present fields. The evidence must count per CALL. `TranscriptEntryPayload.toolCalls` is internal to Router, so the eval decodes the durable JSON form the reading already builds.

    ## Placement decision, measured

    The grader tests stay in the nested `IntegrationTests` package.
    - The gates the card meant (`ACP_TIER3`, `ACP_EVAL`) no longer exist; the package split already makes these tests ungated.
    - `.github/workflows/ci.yml` passes `integration-package-path: IntegrationTests` to the shared workflow, on `push` to main, on every `pull_request`, and on `workflow_dispatch`. The integration job therefore runs on every push.
    - To reach `PythonCLIGraders` from the root unit target, the file must move into the shared `Tests/FoundationModelsACPAgentTestSupport/` library. That would either move all four graders — two of which spawn subprocesses and belong to the eval — or split one grader out of the file its own header calls "the four mechanical graders". That cost is not worth a placement the package split already gives.

    The reason goes in the file.
  timestamp: 2026-09-03T18:34:22.256934+00:00
- actor: claude-code
  id: 01m1m9dz102pevewzqmgczgscj
  text: |-
    ## The measurement that changed the design — read this before touching the grader again

    My first implementation asserted `wireRunCodeCallCount == transcriptRunCodeCallCount`, where the wire side counted the client's tool calls whose TITLE is `runCode`. The scripted driven turn in `PythonCLISubjectTests` refused it:

    ```
    failed readings: the wire holds one tool call for each runCode call the transcript announced (2 against 1)
    ```

    The five wire tool calls of that CORRECT run:

    ```
    01M1M954JG4WJE441P0E1TCZM1  title=runCode        completed
    01M1M954JVQYZHWTEQBJE8NAFA  title="execute shell" completed
    scripted-call-1             title=runCode        completed
    scripted-call-3             title=wait           completed
    scripted-call-2             title=wait           completed
    ```

    The transcript announced ONE `runCode` call, `scripted-call-1`. The second `runCode`-titled call carries a ULID, not a transcript call id: the settlement projection mints it from the operation's `correlationID`, because the code-mode host stamps every `OperationEvent` with the outer `runCode` tool. `completedShellEventCount(in:)` already recorded that stamping fact in its own doc comment.

    So a count of `runCode` TITLES is above the announced count on a correct run. Asserting equality on titles is exactly the flaky, unpromised ratio the card warns against. The match is now by TOOL-CALL ID, which the projection really does promise: Router emits one `toolCall` session event per announced call carrying `call.id`, `EventProjection.projectToolCall` sends the creating `tool_call_update` under that same id, and `ACPSessionState.toolCalls` is keyed by id.

    The failed title-based approach and this measurement are written into the grader's doc comment so the next agent does not repeat it.

    ## The two invariants the body now asserts

    1. `projectedRunCodeCallCount == transcriptRunCodeCallCount` — the wire carries a tool call for EACH `runCode` call the transcript announced, matched by id. Strict equality, promised by the projection.
    2. `shellStreamNotificationCount >= transcriptCompletedShellEventCount` — the wire holds AT LEAST ONE shell notification for EACH completed shell run the transcript recorded. `TerminalStream.project(_:)` turns each run's `.completed` event into one `terminal_update` carrying `exitStatus`, and output chunks are coalesced. So equality is NOT promised, and `>=` is. This is the reading that catches the defect the card names: 40 transcript shell runs against 1 wire notification now FAILS.

    Presence readings stay for the verb paths and for "at least one call really settled". Each count reading names both counts in its rationale, so a failure reports what disagreed.

    ## Evidence sharpening this needed

    `transcriptRunCodeSnippets` counts EVENTS, not calls (`Transcript.ToolCalls` is a batch), so no count comparison was possible with the present fields. `PythonCLIToolTrafficEvidence` gained `transcriptRunCodeCallCount` and `projectedRunCodeCallCount`; `runCodeCallCount` was never shipped. `recordedRunCodeTraffic(in:)` decodes the entry's durable JSON into a local `RecordedToolCallsEntry` to read each call's `id` and `toolName`, because `TranscriptEntryPayload.toolCalls` is internal to Router.

    ## The planted transcript, resolved

    Resolved by the first option the card offers: the file header now says plainly that no grader has a transcript parameter, so no case gives the fabricated text to a grader as an argument, and no case shows a grader that refused a lie handed to it. What the cases DO show is that a fabricated file in the workspace does not move the verdict — and the workspace IS an input, because `PytestGreen` and `CLIRuns` run their subprocess in that directory. The same misleading claim sat in `PythonCLIGraders.swift`'s own header and in two doc comments; all are corrected.

    ## Working tree note for the commit step

    `git status` shows four files I did NOT touch: `README.md`, `Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift`, `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift`, `plan.md`, plus the untracked `cli-plan.md`. They belong to the other work the dispatch note named. They also explain why the root suite now reports 351 tests against the 350 baseline: `DocumentationSyncTests` gained a case. Do not sweep them into this card's commit.
  timestamp: 2026-09-03T18:45:20.544060+00:00
- actor: claude-code
  id: 01m1m9ea29qvg08c6qzrxmwmnd
  text: |-
    ### implement — changed
    - evidence: 4 files — `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Evaluations/PythonCLIGraders.swift`, `.../PythonCLISubject.swift`, `.../EvaluatorHonestyTests.swift`, `.../PythonCLISubjectTests.swift`
    - RED observed twice against the present presence-only code, before any grader change:
      1. `toolTrafficFailsWhenTheWireCarriedFewerShellNotificationsThanRuns` — evidence with 40 transcript shell runs against 1 wire notification, every reading non-zero. The grader returned `PythonCLIGradedVerdict(passed: true, rationale: "all 5 transcript and wire readings agree")`. `#expect(!verdict.passed)` failed.
      2. `toolTrafficFailsWhenTheWireCarriedFewerRunCodeCallsThanTheTranscript` — 3 announced `runCode` calls against 1 on the wire. Same `passed: true` rationale. Run of the two: 5 tests, 4 issues; the other 3 cases passed.
    - A THIRD RED came from the driven scripted turn and corrected the design: `theScriptedSubjectDrivesTheWireAndCollectsAgreeingEvidence` failed my first title-based equality with `(2 against 1)` on a correct run. The invariant is now matched by tool-call id. See the comment above.
    - GREEN: `swift test --package-path IntegrationTests --filter 'EvaluatorHonestyTests|PythonCLISubjectTests|PythonCLIDatasetTests'` → 17 tests in 3 suites passed, 0 failed. `EvaluatorHonestyTests` alone → 12 tests passed.
    - Root `swift test` → 351 tests in 34 suites passed, 1 pre-existing known issue. (The 351 against the 350 baseline comes from another agent's `DocumentationSyncTests` edit, not from this card.)
    - `swift build --build-tests` and `swift build --build-tests --package-path IntegrationTests` → zero compiler warnings, zero errors.
    - The live eval suites were never run; every nested-package run was filtered.
    - next: `/review`
  timestamp: 2026-09-03T18:45:31.849963+00:00
- actor: claude-code
  id: 01m1m9s610nd1nbr8wp9cryzxz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 5d1bfcc). 7 validators ran, 0 failed. 0 findings, 0 confirmed, 0 refuted. 4 source files read, 2 `.kanban/` files excluded by the ignore rule.
    - next: the task moves to done. No open finding is on the card.
  timestamp: 2026-09-03T18:51:28.160829+00:00
- actor: claude-code
  id: 01m1m9sxfcamsx89a60xnpx78e
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 source files under IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Evaluations/: PythonCLIGraders.swift, PythonCLISubject.swift, EvaluatorHonestyTests.swift, PythonCLISubjectTests.swift. The grader now compares the transcript counts against the wire counts. `runCode` calls are strict equality, matched by tool-call id. Shell traffic is "at least one notification for each completed run", because `TerminalStream.project` puts the output chunks together.
    - test: green — the filtered nested run, 17 tests in 3 suites passed. Root `swift test`, 351 tests in 34 suites passed, 1 pre-existing known issue. Both packages `build --build-tests` with zero warnings.
    - RED watched first: both disagreement cases returned `passed: true` against the presence-only code. A third RED corrected a title match to an id match, because the settlement projection makes a second `runCode`-titled call on a correct run.
    - commit: 5d1bfcc — 6 files, 409 insertions, 77 deletions. Local only. The four files of the other concurrent work stayed unstaged.
    - review: clean — `review sha HEAD~1..HEAD`, 7 validators attempted, 0 failed, 0 findings.
    - next: The card is in `done`. No open finding stands.
  timestamp: 2026-09-03T18:51:52.172929+00:00
position_column: done
position_ordinal: a980
title: Make the ToolTraffic grader compare the transcript and the wire, not only their presence
---
## What
`PythonCLIGraders.toolTraffic` at `Tests/FoundationModelsACPAgentTests/Evaluations/PythonCLIGraders.swift:195-212` builds five readings and fails when any is false. Each reading is a presence check: a `contains`, or a count `> 0`. The grader never compares a transcript count against a wire count.

The card that built the eval (^sdwc6d8) states the rule this grader was to enforce, and plan.md §20.3 item 3 repeats it: "A sample passes `ToolTraffic` only when both readings agree; a transcript with tool traffic that never reached the wire is a projection defect, and the eval must catch it."

A run with 40 shell operation events in the transcript and one notification on the wire passes today. That is the exact defect the grader exists to catch.

## Why
The grader's name says agreement and its documentation says agreement. Presence is a weaker claim, and the eval is the only test in the package that watches a real agentic loop, so a projection defect there has no other tripwire.

## How
`PythonCLIToolTrafficEvidence` already carries both sides: `transcriptRunCodeSnippets`, `transcriptCompletedShellEventCount`, `completedRunCodeCallCount`, `shellStreamNotificationCount`. Decide what "agree" means for each pair and assert it, rather than that each is non-zero. At least:
- The number of completed `runCode` calls on the wire matches the number the transcript recorded.
- A transcript that recorded shell traffic has streamed output on the wire in a proportion the projection guarantees. If the projection does not guarantee a one-to-one count — chunk coalescing is a real reason — then define the invariant that IS guaranteed, write it in the doc comment, and assert that. Never assert a ratio the projection does not promise, or the eval becomes flaky for a correct run.

Update the doc comment to state the invariant the code now checks, in the same words.

## Acceptance Criteria
- [ ] `toolTraffic` fails a synthesized evidence value whose transcript side and wire side disagree, with every reading non-zero
- [ ] `toolTraffic` passes a synthesized evidence value where the two sides agree
- [ ] The doc comment states the invariant the body asserts
- [ ] The ungated unit tests over the grader cover both cases
- [ ] `swift test` → green

## Tests
- [ ] The `toolTraffic` cases in `Tests/FoundationModelsACPAgentTests/Evaluations/EvaluatorHonestyTests.swift` — they take no workspace and are pure unit tests over the struct, so the disagreement case is cheap to add
- [ ] Watched to fail first: the disagreement case must fail against the present presence-only code

## Note for the same file
`EvaluatorHonestyTests` plants a `lyingTranscript` beside each broken workspace, and the file's own comment at line 12 records that "the graders take no transcript parameter at all, so the lie has no way in". The planted transcript is decorative: it cannot influence a function that never receives it. The tests do prove the graders read the disk, which is their real value. Either say that plainly in the file header, or give one grader the transcript and prove it still refuses the lie. Do not leave a reader thinking the lie was resisted when it was never delivered.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.