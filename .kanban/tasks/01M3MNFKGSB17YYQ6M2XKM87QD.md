---
comments:
- actor: claude-code
  id: 01m3qxbwkf8pze8c2a9gqzw65h
  text: |-
    Research and implementation notes.

    - The pinned FoundationModelsExtras (3de1179) already contains 70ad74d and the `TelemetryTestSupport` product. Thus `swift package update FoundationModelsExtras` was not necessary, and Package.resolved has no change.
    - `TelemetryCapture` of Extras reads span names, span attributes, log messages, log metadata values, metric names and metric dimensions. It does NOT read span events, recorded errors or the span status. swift-otel exports `span.recordError(error)` as an `exception` event with `exception.message = String(describing: error)`, and `withSpan` and `TracedCall.run` call `recordError` on each error. Thus the new test also reads the events, the recorded errors (as their description) and the status message of each span.
    - The capture sees only records of its own task tree. Router and Extras write their log records and metrics in the detached task of a Router session, thus those do not come to the capture. The Router tracer is given explicitly, thus the Router spans and the Extras tool span `FoundationModelsExtras.tool` do come to the capture. The Router and Extras content-safety tests prove their own logs and metrics.
    - Driven paths: initialize; session/new with a config MCP server (the loopback `mcp-test-server` with a marked `env` value), an unknown `config.yaml` section with a marked value, an `AGENTS.md` with marked content, and a project `Instructions.md` whose bytes are not UTF-8 and hold a marker (this writes the `file.path` warning); one prompt with a marked text that runs two `runCode` calls (marked arguments; an output that the snippet joins at run time, so the output marker is not in the arguments; and the eliciting loopback tool), a marked elicitation answer, and a marked model response; `/help` with marked arguments; one held prompt with a marked text that the client cancels; a session/new with a client http MCP server with a marked `headers` value at a port where nothing listens (the connect fails, so `mcp_connect_failures` and an error span are recorded); session/close.
    - The test expects the span names initialize, sessionNew, prompt, command, elicitation, mcpConnect, cancel and `FoundationModelsExtras.tool`; the metrics prompts, prompt_duration, active_sessions, commands and mcp_connect_failures; and the log metadata keys client.name, config.section, file.path, elicitation.id and cancel.result. Thus an empty capture cannot pass.
    - The file path is logged on purpose (`file.path`, an identifier), thus the markers are in the file content and not in the path.
    - Red check (one time): a temporary `span.attributes["red.check"] = "\(params.prompt)"` and a span event with the prompt in `prompt(_:)` made the test fail with 4 issues (the capture found the prompt text, the command arguments and the cancelled prompt text on the attribute; the span-detail check found the event). The temporary lines are removed.
    - Leaks found: none. No production change for leaks was necessary.
    - Shared helper: `ScriptedPromptFixture.makeRunCodeCall(code:)` now gives one `runCode` step; `makeToolPromptScript(code:)` uses it.
  timestamp: 2026-09-30T01:02:50.991543+00:00
- actor: claude-code
  id: 01m3qxc89j9fhvt4w6mq6tn5hf
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift (`makeRunCodeCall(code:)`), Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift (doc comment names the proof). `swift test --filter TelemetryContentSafetyTests`: 1 test passed; red check with the prompt in a span attribute and an event: failed with 4 issues, then reverted. `swift test`: 667 tests in 76 suites passed (1 known issue, as before). `swift build --build-tests` in the root and in IntegrationTests/: zero compiler warnings (only the SwiftPM "missing creator for mutated node" note of the mlx-swift bundle, which is not from this change). Leaks found: none.
    - follow-up: ^rcy24zj (the Extras `TelemetryCapture` does not read span events, recorded errors or the status).
    - next: /review
  timestamp: 2026-09-30T01:03:02.962438+00:00
- actor: claude-code
  id: 01m3qxqbj32erysntckf0hygfz
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 1e1f9b9); 1 finding, 1 confirmed, 0 refuted — Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift:368 (code-hygiene/idioms-swift, ReplaceForEachWithForLoop). The file is new in this commit, so the rule that drops refactors of existing tests does not apply.
    - next: Replace each `.forEach { ... }` in TelemetryContentSafetyTests.swift with a for-in loop. Then commit and review again.
  timestamp: 2026-09-30T01:09:06.755190+00:00
- actor: claude-code
  id: 01m3qxqqdkeyeyq19rwxdh9a3w
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — TelemetryContentSafetyTests.swift (new), ScriptedPromptFixture.swift, ACPAgentTelemetry.swift
    - test: green — swift test 667 tests pass
    - commit: 1e1f9b9
    - review: findings — Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift:368
  timestamp: 2026-09-30T01:09:18.899843+00:00
- actor: claude-code
  id: 01m3qy0jw6tbbpdtankwxfbvf0
  text: |-
    Correction of the finding ReplaceForEachWithForLoop (TelemetryContentSafetyTests.swift:368).

    - `SpanAttributes` (swift-distributed-tracing) is not a `Sequence`. Its only public walk is `forEach(_:)`. Thus a `for`-in loop over it does not compile, and each walk of it must call `forEach`.
    - Fix: the file does not walk the attributes. The new `attributeText(of:)` returns `String(describing: attributes)`, one text that holds each key and each value. `detailTexts(of:)` uses that text for each event and each recorded error. This also removes the `var` accumulator and the `swiftformat:disable:next preferForLoop` comment.
    - The fix depends on the default description of `SpanAttributes`, which names each key and value. A new test `spanDetailReaderSeesEachAttribute()` proves this, so a later description that hides the values makes the test fail.
    - TDD: RED — the new test did not compile (`attributeText` did not exist). GREEN — `swift test --filter TelemetryContentSafetyTests`: 2 tests passed.
    - The other files of commit 1e1f9b9 (ACPAgentTelemetry.swift, ScriptedPromptFixture.swift) contain no `.forEach`.
    - Note: the Extras `TelemetryCapture.attributePlaces(of:)` has the same `forEach` walk. It is in the Extras repository, thus it is not in the scope of this card.
  timestamp: 2026-09-30T01:14:09.158017+00:00
- actor: claude-code
  id: 01m3qy0ntsazbtmz35h9699y6h
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift (no `.forEach`; new `attributeText(of:)` and test `spanDetailReaderSeesEachAttribute()`). `swift test --filter TelemetryContentSafetyTests`: 2 tests passed. `swift test`: exit 0, 668 tests (667 before + 1 new; count from `swift test list`), 1 known issue as before. Zero compiler warnings (only the SwiftPM "missing creator for mutated node" line of the mlx-swift bundle). Finding flipped to [x]. Not committed.
    - next: /test, /commit, /review
  timestamp: 2026-09-30T01:14:12.185119+00:00
depends_on:
- 01M3MNC26MHCGN4R7BVKFQVQQB
- 01M3MNF2Y6B98SQ03420B65G02
- 01M3MNF37E55WV9B2778MDD7KZ
- 01M3MNF3HX2STG00W3GBT21BAS
- 01M3MNF9A7FRPJJ3JZA503GB5G
- 01M3MNF9KBQQ13EQQPFBFCX8KF
position_column: doing
position_ordinal: '80'
title: 'OTel 10: content-safety test for all spans, logs and metrics of the agent'
---
## What
Design items 4 and 5: prove the no-content rule for all telemetry of this package — span attributes, log messages, log metadata and metric dimensions. Use the shared content-safety helper of FoundationModelsExtras: the `TelemetryTestSupport` product (Extras card ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G). This task waits for OTel 3 to OTel 9 on this board. FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d); run `swift package update FoundationModelsExtras` before you start. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

The model is `FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift` and its `SpanContentSafetyTests`: drive real work with fixture content, read every recorded value, and fail when a value carries a piece of that content.

- [x] OTel 3 already adds `TelemetryTestSupport` to the test target. Use its `TelemetryCapture` with the test rules in OTel 3 (no `LoggingSystem.bootstrap`, `InstrumentationSystem.bootstrap` or `MetricsSystem.bootstrap`; make the agent inside the capture).
- [x] Include the Extras tool-call span `FoundationModelsExtras.tool` (names in `ExtrasTelemetry.swift`): the tool-argument and tool-output fixtures must not appear on it.
- [x] Add `Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift`. Use one set of unique fixture strings for: the prompt text, the command arguments, the model response (through `ScriptedModel`), a tool argument and a tool output, an elicitation answer, an MCP server `env` value and `headers` value, and a file content read by `InstructionsAssembler`.
- [x] Drive, with the recorders of the helper: initialize, session/new with one config MCP server, one prompt with a tool call, one slash command with arguments, one elicitation round trip, session/cancel and session/close.
- [x] Give all recorded spans, log records and metrics to the helper, and assert that no recorded value contains a fixture string.
- [x] Update the doc comment of `ACPAgentTelemetry` (OTel 1) to name this test as the proof of the rule, as `RouterTracing` does.

## Acceptance Criteria
- [x] The test drives each path that OTel 3 to OTel 9 instrumented, and each of those paths records at least one span, log record or metric (the test asserts this, so an empty recorder cannot pass).
- [x] No recorded span attribute, log message, log metadata value or metric dimension contains a fixture string.
- [x] If a later change puts the prompt text in a span attribute, this test fails (check this one time in the red step of `/tdd`).

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift` as above.
- [x] Run `swift test --filter TelemetryContentSafetyTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel

## Review Findings (2026-09-29 20:04)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift:368` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
