---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7t9jazs3kjpdjme564bzhcg
  text: |-
    ### review — findings
    - evidence: review sha 9ee30fe~1..9ee30fe — 2 findings (2 confirmed, 1 refuted, 7 attempted, 0 failed). Tests/FoundationModelsACPAgentTests/ScriptedCompactionStopTests.swift:20, Tests/FoundationModelsACPAgentTests/ScriptedPassCancellationTests.swift:19 (reuse/reuse).
    - next: Declare one shared `LabelArguments` struct for the two suites. Then review again.
  timestamp: 2026-11-19T16:17:21.401759+00:00
- actor: claude-code
  id: 01m7t9p64aj4p4s12jzbf2gx96
  text: |-
    ### finish iteration 2 — implement and test
    - implement: changed — Tests/FoundationModelsACPAgentTestSupport/LabelArguments.swift (new, one public `@Generable` struct); the two copies are removed from ScriptedCompactionStopTests.swift and ScriptedPassCancellationTests.swift. Both review findings are checked.
    - test: green — swift build --build-tests "Build complete!", 0 compiler warnings; swift test --skip-build: 2597 tests in 271 suites passed, 1 known issue (intended).
  timestamp: 2026-11-19T16:19:27.498875+00:00
position_column: review
position_ordinal: '80'
title: A cancelled scripted pass stops before its next step
---
Found during ^dxtwmw0.

`ScriptedSessionBackend.play` does not check cancellation between steps. Only the gate, hold and tool-body waits stop on a cancel. The `acp-agent-stub` container has no observer, so `turn?.takeAgain()` does not throw either.

When Router stops a model call at a tool result (compaction yield, no-op stop), it cancels the stream task. The old backend can then continue: it appends the `.toolOutput` entry and plays the next step, for example a second `agents` tool call, on the old backend. The new backend then also plays that step.

## Change
- `play` checks `Task.checkCancellation()` before each step.

## Tests
- A pass whose task is cancelled during the body of its first tool call does not invoke the tool of its second step.

#bug #scripted

## Review Findings (2026-11-19 10:14)

> Scope: `review sha 9ee30fe~1..9ee30fe` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 0 not reviewed.

- [x] `Tests/FoundationModelsACPAgentTests/ScriptedCompactionStopTests.swift:20` `reuse/reuse` — `LabelArguments` is a second copy of the same `@Generable` argument struct, `label: String`, that `ScriptedPassCancellationTests` declares. Both files carry it, so one shape is written twice. Declare one `@Generable` argument struct in `FoundationModelsACPAgentTestSupport`, and use it from both suites. Or keep a single declaration in one suite and reference it from the other.
- [x] `Tests/FoundationModelsACPAgentTests/ScriptedPassCancellationTests.swift:19` `reuse/reuse` — `LabelArguments` duplicates the argument struct of `ScriptedCompactionStopTests`. The two suites declare the same `label: String` `@Generable` shape. Use one shared `LabelArguments` from the test-support target for both suites, as in the finding on ScriptedCompactionStopTests.swift:20.
