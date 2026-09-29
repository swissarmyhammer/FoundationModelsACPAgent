---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n4bb684fyxfvm8x5xk3zvw
  text: |-
    Research:
    - `swift package update FoundationModelsExtras` moved only the Extras pin: 0dc42cf to 6c399a4 (Extras origin/main, OTel A to E). No other pin moved. `Package.resolved` is not tracked in git.
    - `TelemetryCapture` (Extras `Tests/TelemetryTestSupport`) bootstraps logging one time with `RoutingLogHandler`. The factory ignores the logger label (`{ _ in RoutingLogHandler() }`), and `InMemoryLogHandler.Entry` has only `level`, `message`, `error` and `metadata`. Thus a captured record does NOT hold the logger label. A test cannot assert the label `FoundationModelsACPAgent.PromptTurn` through the capture. This is a gap between the acceptance criterion and the Extras helper.
    - The ACP `Connection` makes its read loop with `Task { }` in its `init`, and runs each notification inline in that loop. Thus a harness made inside the capture sends the agent log records to the capture, and a request after `session/cancel` runs after the cancel handler.
    - `turnLogger` has call sites in TurnState.swift, PromptTurn.swift, TerminalStream.swift and EventProjection.swift. `sessionLogger` has call sites in RoutedACPAgent.swift and SessionSetup.swift.
  timestamp: 2026-09-28T23:07:09.896624+00:00
- actor: claude-code
  id: 01m3n4tzm9x9hsq9z2467vxemy
  text: |-
    Blocker: the Extras version that this task needs does not build with the pinned Router.

    What I did:
    - `swift package update FoundationModelsExtras` moved only the Extras pin, from 0dc42cf to 6c399a4. No other pin moved.
    - I added `TelemetryTestSupport` to the test target and wrote `SessionSurfaceLoggingTests` (RED step).
    - `swift test --filter SessionSurfaceLoggingTests` failed in the build of the library target, before a test ran:
      `Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift:159:24: error: 'ModelRef' is ambiguous for type lookup in this context` (the same error also at ProfileDoctor.swift lines 206, 245 and 469, and follow-on key path errors at lines 247 and 470). The candidates are `FoundationModelsExtras.ModelRef` and `FoundationModelsRouter.ModelRef`.

    Cause:
    - Extras commit d682e45 (2026-09-26, "feat(model-pool): move the work queue from the router into the core target") adds `public struct ModelRef` in `Sources/FoundationModelsExtras/ModelPool/ModelRef.swift`. It is the first Extras commit after the old pin 0dc42cf. The TelemetryTestSupport commits (9b97617 and later, OTel A to E) all come after it. Thus each Extras version with `TelemetryCapture` also has `ModelRef`.
    - The pinned Router bbad3ce still declares its own `public struct ModelRef`. The newer Router (after the work queue move) is the Router API adoption of card ^tz867gz, which is blocked.

    State now:
    - Per the orchestrator rule, I restored the old Extras pin (0dc42cf; `Package.resolved` is the same as before), reverted `Package.swift`, and deleted the test file. `swift build --build-tests` passes on the old pin. No source file of this project is changed.

    Research for the next attempt (in the comment before this one): `TelemetryCapture` does not keep the logger label of a record (`RoutingLogHandler` ignores the label, and `InMemoryLogHandler.Entry` has no label). Thus the acceptance criterion "one .notice record with the label FoundationModelsACPAgent.PromptTurn" cannot be asserted through the capture. A possible way: assert the label of the logger that the agent makes (for example `ACPAgentTelemetry.logger(.promptTurn).label`), or an Extras change so that the capture keeps the label.

    Decision needed from a person: (a) unblock ^tz867gz so that Router and Extras move together, or (b) allow a qualification `FoundationModelsRouter.ModelRef` in ProfileDoctor.swift so that the new Extras builds with the old Router.
  timestamp: 2026-09-28T23:15:42.345100+00:00
- actor: claude-code
  id: 01m3n4v4ew9xty6b9xq13mw59g
  text: |-
    ### implement — stuck
    - evidence: Extras 6c399a4 (and each Extras commit from d682e45 on, which includes all OTel A to E commits) adds `public struct ModelRef`. With the pinned Router bbad3ce, `Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift` fails: "'ModelRef' is ambiguous for type lookup in this context" (lines 159, 206, 245, 469). Extras pin restored to 0dc42cf, `Package.swift` reverted, test file deleted. `swift build --build-tests` passes. No project file changed.
    - next: a person decides: unblock ^tz867gz (move Router and Extras together), or allow a `FoundationModelsRouter.ModelRef` qualification in ProfileDoctor.swift. Also decide how to assert the logger label, because `TelemetryCapture` does not keep it.
  timestamp: 2026-09-28T23:15:47.292470+00:00
- actor: claude-code
  id: 01m3n4vmwxdkg6s72b6pswj3vp
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no project files changed. Each Extras version with TelemetryCapture (from d682e45 on, including 6c399a4) adds a public ModelRef. With the pinned Router bbad3ce, Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift:159, 206, 245, 469 give "'ModelRef' is ambiguous for type lookup in this context". The Extras pin is back at 0dc42cf.
    - Also: TelemetryCapture does not keep the logger label, so the label criterion cannot be checked through the capture as written.
    - test, commit, review: not run
    - next: a person must decide: (1) unblock ^tz867gz so Router and Extras move together, or (2) permit a FoundationModelsRouter.ModelRef qualification in ProfileDoctor.swift. A person must also decide how to test the label criterion.
  timestamp: 2026-09-28T23:16:04.125933+00:00
- actor: claude-code
  id: 01m3q6c1fafsntgd5kbcyspx0k
  text: 'Note from card ^f9513f2 (not committed yet, in the working tree): `Agent/PromptTurn.swift` is now `Agent/PromptExecution.swift` (type `PromptExecution`). `Agent/TurnState.swift` is now `Agent/PromptState.swift`. The logger `turnLogger` (os.Logger, category "PromptTurn") is now `promptLogger` (category "PromptExecution") in `Agent/PromptState.swift`. When this card moves the logger to swift-log, use the name `promptLogger` and the label "PromptExecution".'
  timestamp: 2026-09-29T18:20:58.730665+00:00
- actor: claude-code
  id: 01m3qgajtt9tzc86jqxqycykj4
  text: |-
    Picked up again (attempt 2). The two blockers are resolved.

    1. Package pins: Router c49e453 and Extras 3de1179 (Router and Extras moved together, card ^tz867gz is done). The pinned Extras has the `TelemetryTestSupport` product and `TelemetryCapture`. Thus no `swift package update` is necessary.
    2. Design decision of the user (final): `TelemetryCapture` does not keep the logger label. The test asserts the label of the logger that the agent makes (`ACPAgentTelemetry.logger(.promptExecution).label`), and the test asserts the record content (level, message, metadata) through the capture.

    Name changes since the card was written: `PromptTurn.swift` is `Agent/PromptExecution.swift`. `TurnState.swift` is `Agent/PromptState.swift`. `turnLogger` is `promptLogger`, category "PromptExecution". Thus the label of the cancel record is `FoundationModelsACPAgent.PromptExecution`, not `FoundationModelsACPAgent.PromptTurn`. Commit 66bfd3c added log calls in PromptExecution.swift (the cut stop report) and EventProjection.swift (the repetitionStopped notice). This task moves them too.

    Research:
    - `promptLogger` call sites: PromptState.swift, PromptExecution.swift, EventProjection.swift, TerminalStream.swift. `sessionLogger` call sites: RoutedACPAgent.swift, SessionSetup.swift. `initializationLogger`: Initialization.swift only. `resumeLogger`: SessionResume.swift only.
    - The otel-design.md file in the old scratchpad does not exist now. The card text holds the rules.
    - swift-log takes the message as a non-escaping autoclosure. Thus the "copies for the log line" of the os.Logger code are not necessary now.
    - Router uses the metadata keys `model.ref`, `tokens.in` and `tokens.out`. Extras uses `tool.name`. The agent uses the same keys for the same values.
    - Some old messages held content or content risk: `String(describing: event)` of a SessionEvent (an `answered` event holds the answer text), the description of a DiscoveryPrimingFailure (its `underlying` text can hold the prompt), and the description of an error. The new records log the case name or the error type in place of these.
  timestamp: 2026-09-29T21:14:56.730477+00:00
- actor: claude-code
  id: 01m3qgm7tpskmh2s9f0b5znw8j
  text: |-
    Progress:
    - RED 1: `promptExecutionLoggerHasTheModuleLabel` did not compile (`ACPAgentTelemetry` had no `logger`). After `ACPAgentTelemetry.logger(_:)` and `LoggerCategory` were added, it passed.
    - RED 2: `ignoredCancelOfAnUnknownSessionWritesOneNoticeWithTheSessionIdInMetadata` failed for the expected reason: 0 records with `session.id` in the capture, because the os.Logger record does not go to the capture.
    - Design: `ACPAgentTelemetry.logger(_ category:)` makes a new swift-log `Logger` at each call, with the label `FoundationModelsACPAgent.<Category>`. Categories: Session, PromptExecution, Initialization, SessionResume. The `SpanName` prefix and the logger label share one private `moduleName` constant. New metadata helpers: `sessionMetadata`, `modelMetadata`, `errorMetadata` (type name only), `caseName(of:)` (enum case without payload). New `LogMetadataKey` keys for the values that the old messages held.
    - `EventProjection.usageSummary` (a String) becomes `usageMetadata` (tokens.in, tokens.out, context.fill), so the cut stop record carries the numbers as metadata.
    - `report(failure:)` now takes the error and logs its type, not `String(describing:)` of it.
    - `sessionCancel` logs the cancel result as a case name (`requested` / `nothingToCancel`) through an exhaustive switch.
  timestamp: 2026-09-29T21:20:13.142333+00:00
- actor: claude-code
  id: 01m3qgzxygpv1pyyhrtka4rbj2
  text: |-
    ### implement — changed
    - evidence: `swift test`: 627 tests in 71 suites passed (625 before, plus 2 new), 1 known issue (the old intentional `withKnownIssue` in HarnessSmokeTests), zero compiler warnings. `swift test --filter SessionSurfaceLoggingTests`: 2 of 2 passed. `swift build --build-tests` in IntegrationTests/: Build complete, no warnings. `rg "promptLogger|sessionLogger|initializationLogger|resumeLogger|usageSummary"` finds nothing.
    - files: Package.swift; Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift; Sources/FoundationModelsACPAgent/RoutedACPAgent.swift; Sources/FoundationModelsACPAgent/Agent/{PromptState,PromptExecution,EventProjection,TerminalStream,Initialization,SessionResume,SessionSetup}.swift; new Tests/FoundationModelsACPAgentTests/SessionSurfaceLoggingTests.swift.
    - notes: the stderr log level rule of acp-agent (`TelemetryBootstrap.standardErrorLogLevel = .warning`) is not changed, and its tests pass. The test target also links the swift-log `Logging` product, because the new suite reads `Logger.Level`. The cwd mismatch record of the resume holds no path; the refusal error gives both paths to the client.
    - next: /review
  timestamp: 2026-09-29T21:26:36.240686+00:00
- actor: claude-code
  id: 01m3qhn2w9zemy7xn5cq58j9za
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 3b44c15). 23 findings confirmed, 2 refuted. PromptExecution.swift:735 (completeness/inverse-operation-coverage). ACPAgentTelemetry.swift:187, 191, 195, 199, 203, 206, 209, 213, 217, 220, 223, 227, 230, 234, 238, 241, 244, 248, 251, 254, 257, 260 (code-hygiene/dead-code-swift, superfluousIgnoreCommand).
    - next: Do the items in "Review Findings (2026-09-29 16:28)". Then run the review again. The task stays in review.
  timestamp: 2026-09-29T21:38:09.417049+00:00
- actor: claude-code
  id: 01m3qhnggvr86vbcbm48kr37xm
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 11 files (Package.swift, ACPAgentTelemetry.swift, RoutedACPAgent.swift, Agent/*.swift, SessionSurfaceLoggingTests.swift new)
    - test: green — swift test 627 tests pass; IntegrationTests build ok
    - commit: 3b44c15
    - review: findings — PromptExecution.swift:735; ACPAgentTelemetry.swift:187-260 (22 x superfluousIgnoreCommand)
  timestamp: 2026-09-29T21:38:23.387265+00:00
- actor: claude-code
  id: 01m3qj6tcrvrf7qc7v8gvtfqfq
  text: |-
    Review findings correction:
    - Finding 1 (`cancelResultName` coverage): new test `cancelOfARunningPromptWritesOneInfoWithTheCancelResultInMetadata` in SessionSurfaceLoggingTests. It makes a scripted fixture with a held pass inside a `TelemetryCapture`, cancels the running prompt, waits for the record with `Poll.until`, and asserts one `.info` record with `cancel.result` = `requested` and the `session.id` of the fixture. RED proof: with `.requested` mapped to "nothingToCancel" for one run, the test failed on the `cancel.result` expectation. The mapping is restored.
    - Findings 2 to 23 (superfluousIgnoreCommand): the cause was the `// periphery:ignore` marker on the whole `LogMetadataKey` enum. Periphery reports each member that has a reader as a superfluous ignore. The marker is removed. The three keys that nothing read (`commandName`, `mcpServerName`, `elicitationMode`) are removed. The same cause was on the `AttributeKey` enum (its `acpMethod`, `sessionId`, `promptStopReason`, `errorType` and `commandKind` have readers): the enum-level marker is removed, and each of the five values with no reader (`commandName`, `elicitationMode`, `elicitationOutcome`, `mcpServerName`, `mcpServerTransport`) has its own marker. The markers on `MetricDimension` (no member has a reader) and on `tracer(explicit:)` (no caller) stay.
    - Periphery check: `periphery scan --skip-build --index-store-path .build/out` with the flag set of the dead-code-swift rule reports nothing in ACPAgentTelemetry.swift and nothing in any Sources file other than one `var.parameter` in acp-agent/RunCommand.swift, which the rule filters out.
    - A note for OTel 4 is on card ^b65g02: add the three removed keys again when a reader comes.
  timestamp: 2026-09-29T21:47:50.552862+00:00
- actor: claude-code
  id: 01m3qj6wdmzazggn78xra89w8r
  text: |-
    ### implement — changed
    - evidence: `swift test`: 628 tests in 71 suites passed (627 before, plus 1 new), 1 known issue (the old intentional `withKnownIssue` in HarnessSmokeTests), zero compiler warnings. Periphery: no finding in the changed files.
    - files: Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift; Tests/FoundationModelsACPAgentTests/SessionSurfaceLoggingTests.swift.
    - next: /review
  timestamp: 2026-09-29T21:47:52.628917+00:00
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
position_column: doing
position_ordinal: '80'
title: 'OTel 3: replace os.Logger with swift-log in the session surface (Session, PromptTurn, Initialization, SessionResume)'
---
## What
Design item 2: remove all `os.Logger` use and use `Logging.Logger` (swift-log). This task changes the first 4 of the 11 `os.Logger` sites. OTel 4 and OTel 5 change the other 7. This task also adds the Extras test helper that the later OTel tasks use. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (this file does not exist now; the card text holds the rules).

Extras: the pinned Extras (3de1179) has `TelemetryTestSupport`. Router and Extras moved together (card ^tz867gz is done), so no `swift package update` was necessary.

Name changes since the card was written: `PromptTurn.swift` is `Agent/PromptExecution.swift`. `TurnState.swift` is `Agent/PromptState.swift`. `turnLogger` is `promptLogger`, category "PromptExecution".

Sites:
- [x] `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift` — `sessionLogger` (category `Session`). Its call site in `Agent/SessionSetup.swift` changed too.
- [x] `Sources/FoundationModelsACPAgent/Agent/PromptState.swift` — `promptLogger` (category `PromptExecution`). The call sites in `PromptExecution.swift`, `EventProjection.swift` and `TerminalStream.swift` changed too, with the log calls of commit 66bfd3c (the cut stop report and the repetitionStopped notice).
- [x] `Sources/FoundationModelsACPAgent/Agent/Initialization.swift` — `initializationLogger`.
- [x] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` — `resumeLogger`.
- [x] In `Package.swift`, add the FoundationModelsExtras `TelemetryTestSupport` product (Extras card ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G) to the test target `FoundationModelsACPAgentTests` only.

Rules for each site:
- Replace `import os` with `import Logging`. The label is `"FoundationModelsACPAgent.<Category>"`, with the same category name as now.
- Do not keep the logger as a global `let` or a `static let`. A logger made before a `TelemetryCapture` starts does not go to the capture (Extras fact). Make the `Logger` at the call, or as a stored property that the instance makes in its `init`.
- Keep the level: `debug` → `.debug`, `info` → `.info`, `notice` → `.notice`, `warning`/`error` → the same level, `fault` → `.critical`.
- Move each interpolated identifier (session id, method name, command name) into log metadata, with a key from `ACPAgentTelemetry.LogMetadataKey` (OTel 1). The message is a fixed string.
- No content rule (design item 4): a log message or metadata value must not hold prompt text, response text, tool arguments, tool output or file content. Where a site logs such a value now, log its size or kind in its place.

## Acceptance Criteria
- [x] The 4 files have no `import os`, no `os.Logger`, and no global or `static let` logger.
- [x] Each changed log call has a fixed message string and puts identifiers in metadata.
- [x] An ignored `session/cancel` for an unknown session writes one `.notice` record with the session id in metadata.
- [x] The logger of that record has the label `FoundationModelsACPAgent.PromptExecution`. Design decision of the user (final): `TelemetryCapture` does not keep the logger label, so the test asserts the label of the logger that the agent makes (`ACPAgentTelemetry.logger(.promptExecution).label`), and asserts the record content (level, message, metadata) through the capture.

## Tests
- [x] Test rules for all OTel tasks on this board: use `TelemetryCapture` from `TelemetryTestSupport`. It uses task-local `withTracer` and `withMetricsFactory`, and it bootstraps logging one time. Never call `LoggingSystem.bootstrap`, `InstrumentationSystem.bootstrap` or `MetricsSystem.bootstrap` in the test process. Make the agent and the harness inside the capture.
- [x] Add `Tests/FoundationModelsACPAgentTests/SessionSurfaceLoggingTests.swift`: in a capture, send `session/cancel` for an unknown session through the harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift`, and assert the captured record (level and `session.id` metadata). Assert the label on the logger that the agent makes.
- [x] Run `swift test --filter SessionSurfaceLoggingTests`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel

## Review Findings (2026-09-29 16:28)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift:735` `completeness/inverse-operation-coverage` — The new function `cancelResultName` maps `CancellationResult` enum cases to strings for logging (write operation), but the test suite only verifies logging for the unknown-session case (line 26-47 of SessionSurfaceLoggingTests.swift), not the known-session case where `cancelResultName` is actually called (line 724). A test should round-trip the successful session cancel to verify that the info log is written with the correct cancel result metadata. Add a test case that calls `sessionCancel` with a known session, then verify that the resulting log record is an info-level message containing the expected cancel result in metadata (e.g., 'requested' or 'nothingToCancel').
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:187` `code-hygiene/dead-code-swift` — var.static `stopReason` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:191` `code-hygiene/dead-code-swift` — var.static `errorType` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:195` `code-hygiene/dead-code-swift` — var.static `errorCase` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:199` `code-hygiene/dead-code-swift` — var.static `modelRef` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:203` `code-hygiene/dead-code-swift` — var.static `toolCallId` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:206` `code-hygiene/dead-code-swift` — var.static `toolName` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:209` `code-hygiene/dead-code-swift` — var.static `entryId` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:213` `code-hygiene/dead-code-swift` — var.static `eventKind` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:217` `code-hygiene/dead-code-swift` — var.static `routerReport` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:220` `code-hygiene/dead-code-swift` — var.static `tokensIn` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:223` `code-hygiene/dead-code-swift` — var.static `tokensOut` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:227` `code-hygiene/dead-code-swift` — var.static `contextFill` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:230` `code-hygiene/dead-code-swift` — var.static `contextTokens` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:234` `code-hygiene/dead-code-swift` — var.static `recordedContextTokens` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:238` `code-hygiene/dead-code-swift` — var.static `resolvedContextTokens` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:241` `code-hygiene/dead-code-swift` — var.static `compactionTriggerFraction` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:244` `code-hygiene/dead-code-swift` — var.static `compactionTargetFraction` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:248` `code-hygiene/dead-code-swift` — var.static `cancelResult` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:251` `code-hygiene/dead-code-swift` — var.static `clientName` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:254` `code-hygiene/dead-code-swift` — var.static `clientVersion` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:257` `code-hygiene/dead-code-swift` — var.static `requestedProtocolVersion` is superfluousIgnoreCommand.
- [x] `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift:260` `code-hygiene/dead-code-swift` — var.static `answeredProtocolVersion` is superfluousIgnoreCommand.
