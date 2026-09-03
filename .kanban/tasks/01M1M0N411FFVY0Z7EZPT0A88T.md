---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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