---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1m5rzn6sjrs6mr66y1nf2vj
  text: |-
    ### research

    Read the file after `^7dwcz2a` rewrote proof 1. The four gaps are found by test name, not by line number.

    Facts that decide each gap:

    - **Proof 4 (`theToolTurnKeepsTheWireOrder`).** `session/prompt` answers `PromptResponse`, whose only field is an optional `_meta`, so the acknowledgement is literally `{"result":{}}` on the wire. `initialize` and `session/new` answer filled results, thus an empty result names the prompt acknowledgement alone. The `UpdateCollector` starts at the client's notification handler, which is downstream of the JSON-RPC response the same wire carried, so the collector alone cannot see the response. A tap on the client end of the transport can: `ACPTransport` is a public protocol (`bytes` plus `write`), and `NDJSONFramer` is public, so a tapping transport records every framed line in wire order and hands the bytes on unchanged. The claim is therefore observable, and the plan calls it a MUST (§8.1).
    - **Proof 3 (`aRealToolCallProjectsAStableUpsertLifecycle`).** The body asserts the `wait` call's `rawOutput`. What the `runCode` call's `rawOutput` carries must be measured, not guessed.
    - **Proof 6 (`aClientDeclaredMCPServerMountsUnderItsOwnNoun`).** `help()` answers an ARRAY of surface paths (`MultiTool.makeHelpDocsHostFunctions`), and the snippet interpreter is JavaScriptCore, so the snippet can reduce the listing to a boolean. That separates the listing source from the answer source.
    - **Proof 2 (`anOutOfRootReadRefusesInBandThroughTheCorrectionField`).** plan.md §11.7 says the seatbelt sandbox "bounds writing and deleting only. Reads are free". The proof reads a file outside the root set, thus the sandbox is not the gate that refuses it. The matched string is Multitool's `PathGuard` wording, which is the files capability's own path check.
  timestamp: 2026-09-03T17:41:27.334652+00:00
- actor: claude-code
  id: 01m1m6c0dfk5n5ec9xqrf2rpaw
  text: |-
    ### implement — changed

    What each proof got, and why:

    **Proof 4 — asserted.** The `{}`-first MUST is now read on the BYTES. A new `WireTap` (`Tests/FoundationModelsACPAgentTestSupport/WireTap.swift`) wraps the client end of the transport, frames each incoming chunk with the public `NDJSONFramer`, keeps the line, and hands the chunk on unchanged. The harness stands the tap only when a caller asks (`makeRecording(agent:tapsWire:)`, default off), so every other suite runs the untapped wire. The proof asserts that the empty-result line — the `session/prompt` acknowledgement — stands before the first `user_message` notification. RED first: the inverted assertion failed with `echoIndex → 4`, `acknowledgementIndex → 3`. The doc now also states what `expectOrderedSubsequence` does not prove: it permits gaps, so it does not prove that exactly one `running` arrives.

    **Proof 3 — asserted AND named.** Measured first: the `runCode` call's `rawOutput` is the pending envelope `{"pending":true,"completionToken":...}`, never the written line, because the run mounts in the background. The body now asserts the `runCode` call's own `rawOutput` (it carries the pending flag, and it does NOT carry the note content), beside the wait call's `rawOutput` that carries the line. The doc names which call carries which answer.

    **Proof 6 — sources separated, correlation asserted.** The snippet now reduces the `help()` listing to two booleans (`mounted=true`, `prefixed=false`), so the listing lines carry no verb text at all, and the echoed line carries the ping alone. The path assertion and the round-trip assertion therefore no longer share a source. The correlation the plan names is asserted through a new reader that reads each update's ANSWER — its `rawOutput` and `content`, never its `rawInput`, because the `runCode` call's `rawInput` carries the snippet source and the snippet names both the verb path and the ping. The set of ids that answer with the ping is exactly the wait call's id.

    **Proof 2 — comments corrected.** The doc no longer says "the sandbox is the only gate". It names Multitool's `PathGuard`, the files capability's own path check, whose wording the matched marker carries, and it records plan.md §11.7's statement that the seatbelt sandbox "bounds writing and deleting only. Reads are free". The pending-permission assertion is marked as the regression tripwire it is, in the doc and beside the assertion. The same overstatement in `Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift` was corrected with it, because it is one cause in two places.

    Negative run (each new assertion inverted): all six new assertions failed, and the diagnostics confirmed the measured values. Restored, then green.

    - evidence: 6 files — Tests/FoundationModelsACPAgentTestSupport/WireTap.swift (new), Tests/FoundationModelsACPAgentTestSupport/Harness.swift, Tests/FoundationModelsACPAgentTestSupport/RecordingClient.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift, Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift
    - next: test
  timestamp: 2026-09-03T17:51:50.703976+00:00
- actor: claude-code
  id: 01m1m6dtsah9wprz2te3s8sset
  text: |-
    ### test — green
    - evidence: root `swift test` — 349 tests in 34 suites passed, 0 failed, 0 skipped, 1 known issue (the pre-existing intentional `withKnownIssue` in `HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps`, which proves the helper catches a reversed pair). `swift build --build-tests` clean, zero warnings. The nested package links the changed test-support product, so `swift build --build-tests --package-path IntegrationTests` ran too: Build complete, zero warnings.
    - next: commit
  timestamp: 2026-09-03T17:52:50.474423+00:00
- actor: claude-code
  id: 01m1m6emn3bdtftgscdanpjsve
  text: |-
    ### commit — changed
    - evidence: 21fe38d test(tier2): close the doc-versus-assertion gaps in proofs 2, 3, 4 and 6 — 7 files changed, 427 insertions, 39 deletions. Local only, not pushed. The untracked `cli-plan.md` was left alone.
    - next: review
  timestamp: 2026-09-03T17:53:16.963279+00:00
- actor: claude-code
  id: 01m1m6mz5rx17ksbkd4pgzyfaj
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 5 files reviewed; the 2 `.kanban/` files are excluded by `.reviewignore`.
    - next: done

    ### finish iteration 1 — done

    One iteration. Every acceptance item is met by an ASSERTION, and no claim was deleted to close a gap.

    - implement — changed (5 source files, 1 of them new)
    - test — green (349 tests in 34 suites, 0 failed, 0 skipped, 1 pre-existing known issue; the nested `IntegrationTests` package builds clean too, because it links the changed test-support product)
    - commit — changed (21fe38d)
    - review — clean (0 findings)
  timestamp: 2026-09-03T17:56:44.344110+00:00
position_column: done
position_ordinal: a780
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
- [x] Every doc comment in the file describes only what its body asserts
- [x] The `{}`-first MUST is asserted, or the sentence is gone and the card records why the fixture cannot observe it
- [x] Proof 3 asserts the `runCode` call's `rawOutput`, or names the carrying call
- [x] Proof 6 asserts the correlation, or the card records why it is not observable
- [x] Proof 2 names `PathGuard` as the mechanism it matches, and marks the permission assertion as a tripwire
- [x] `swift test` → green

## Tests
- [x] The four proofs, each new assertion watched to fail first

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Outcome

Every gap was closed by ASSERTING, not by deleting a claim.

- Proof 4: the `{}`-first MUST is asserted on the raw wire lines, through a new `WireTap` on the client end of the transport. The ordered-subsequence limit is stated in the doc.
- Proof 3: the `runCode` call's `rawOutput` is asserted (the pending envelope, and NOT the written line), beside the wait call's `rawOutput` that carries the line. The doc names each carrier.
- Proof 6: the listing source and the answer source are separated in the snippet, and the `tool_call_update` correlation is asserted — the set of calls whose ANSWER carries the ping is exactly the wait call.
- Proof 2: the doc names Multitool's `PathGuard`, records §11.7's "the sandbox bounds writing and deleting only", and marks the permission assertion as a regression tripwire. The same overstatement in `RecordingClient.swift` was corrected with it.