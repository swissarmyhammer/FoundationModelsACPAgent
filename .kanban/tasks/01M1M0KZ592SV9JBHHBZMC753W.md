---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Close the doc-versus-assertion gaps in tier-2 proofs 2, 3, 4 and 6
---
## What
Four proofs in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` have doc comments that promise more than the bodies assert. A reader takes the comment for coverage. Either assert the claim, or correct the comment. Do not leave the two apart.

### Proof 4 — the acknowledgement order (line 474)
The comment says: "the `{}` response acknowledges first (the prompt call returns), then `user_message`". The body never asserts it. `runToolTurn` awaits `prompt(...)` and then reads the collector, so the position of the acknowledgement against `user_message` is not observable in `updates`. Plan.md §8.1 makes the `{}`-first order a MUST.
- Assert it — record the moment the prompt call returns against the arrival of the first notification — or delete the sentence.
- Also note what the ordering assertion does and does not give: `expectOrderedSubsequence` (`Support/AssertionHelpers.swift:87`) permits gaps, thus the test proves the four markers appear in that relative order and nothing more. It does not prove that no second `running` arrives after a `tool_call_update`. Say so in the comment, or tighten the assertion.

### Proof 3 — the `rawOutput` claim (line 465)
The comment promises "`rawOutput` carrying the tool's real answer". The body reads `waitAccumulated.rawOutput` — the **wait** call — and never asserts the `runCode` call's `rawOutput`. Assert the `runCode` call's `rawOutput`, or state in the comment which call carries the answer and why.

### Proof 6 — the MCP correlation (line 531)
Plan.md §20.1 asks the MCP proof to "confirm that the `tool_call_update` correlation holds". The body reads only the wait call's updates; the MCP answer arrives inside that call's `rawOutput`, and no separate `tool_call_update` for the MCP call is asserted. Also `waitText.contains("alpha.echo")` is satisfied by the `help()` listing that the same snippet returns, so the path assertion and the round-trip assertion partly share one source. Separate the two sources, and assert the correlation the plan names, or record on the card why the correlation is not observable here.

### Proof 2 — two wording defects (lines 382, 414)
- `#expect(pendingPermissionCount == 0)` cannot fail: no code path in this package sends `session/request_permission`, and `Support/RecordingClient.swift:56` records that there is no configurable permission answer. Keep the assertion as a regression tripwire, and say in the comment that it is one — not evidence that the sandbox refused the read.
- The comment says "The sandbox is the only gate". The string the test matches, `"outside workspace boundaries"`, is Multitool's `PathGuard` wording — the files capability's own path check, which is a different mechanism from the seatbelt sandbox. Name the mechanism the test actually exercises.

## Why
A comment that overstates its test is worse than no comment: the next reader stops looking for the coverage. Each of these four is a small edit, and together they decide whether the seven proofs mean what the file says they mean.

## Acceptance Criteria
- [ ] Every doc comment in the file describes only what its body asserts
- [ ] The `{}`-first MUST is asserted, or the sentence is gone and the card records why the fixture cannot observe it
- [ ] Proof 3 asserts the `runCode` call's `rawOutput`, or names the carrying call
- [ ] Proof 6 asserts the correlation, or the card records why it is not observable
- [ ] Proof 2 names `PathGuard` as the mechanism it matches, and marks the permission assertion as a tripwire
- [ ] `swift test` → green

## Tests
- [ ] The four proofs, each new assertion watched to fail first

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.