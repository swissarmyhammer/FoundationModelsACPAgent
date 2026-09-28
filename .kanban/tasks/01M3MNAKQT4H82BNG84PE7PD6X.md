---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mzesjeqkw6d51kmqfh5n9w
  text: |-
    Research:
    - The vocabulary model is `RouterTracing.swift` in the Router checkout (`.build/checkouts/FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`). It is an internal enum with nested enums of `static let` names, a private `prefix`, and `tracer(explicit:)`.
    - Version floors: `swift-distributed-tracing` from 1.4.1 (Router and Extras), `swift-log` from 1.15.1 (Router and Extras), `swift-metrics` from 2.11.0 (Extras).
    - The local `Package.resolved` already holds `swift-metrics` 2.11.0, `swift-log` 1.15.1 and `swift-distributed-tracing` 1.5.0. So the new declarations add no new package, and the family pins do not need to move.
    - Tests use Swift Testing and `@testable import FoundationModelsACPAgent`.
    - periphery counts a test as a caller. The keys that no code and no test reads yet (they wait for OTel 3 to OTel 9) get the `// periphery:ignore` marker with the reason on its own line above it.
  timestamp: 2026-09-28T21:41:40.046978+00:00
- actor: claude-code
  id: 01m3n09nnqc8qdwkr1jt4wzfth
  text: |-
    Implementation landed (TDD: the new test failed first with "cannot find 'ACPAgentTelemetry' in scope", then passed).

    - `Package.swift`: new constants `tracingPackage`/`tracingVersionFloor` (1.4.1), `loggingPackage`/`loggingVersionFloor` (1.15.1), `metricsPackage`/`metricsVersionFloor` (2.11.0), the list `telemetryAPIProducts` (Tracing, Logging, Metrics), and the helper `makeApplePackage(name:from:)`. The swift-argument-parser declaration now uses the same helper. Only the library target links `telemetryAPIProducts`. No `swift-otel`. No telemetry test products.
    - `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift`: `SpanName`, `AttributeKey`, `MetricName`, `MetricDimension`, `LogMetadataKey`, `tracer(explicit:)`, and the "No content" rule. The span name suffix is the Swift name (`FoundationModelsACPAgent.sessionNew`, `FoundationModelsACPAgent.mcpConnect`), because the OTel 6 and OTel 8 cards write the names in that form. `LogMetadataKey` and `MetricDimension.commandKind` reuse the `AttributeKey` constants, so each key string is written one time.
    - `AttributeKey`, `MetricDimension`, `LogMetadataKey` and `tracer(explicit:)` have no reader yet. Each has `// periphery:ignore`, with the reason in its doc comment, in the same shape as Router and Extras. When OTel 3 to OTel 9 read them, remove the markers. periphery reports no finding in the new file.
    - Verification: a temporary file with `import Logging`, `import Metrics` and `import Tracing` compiled in the library target, then I deleted it. `swift test --filter ACPAgentTelemetryTests`: 3 tests (8 + 5 + 1 cases) pass. Full `swift test`: 587 tests in 64 suites pass (1 known issue, from before this change, in HarnessSmokeTests).
    - Package.resolved: all family pins stay the same. SwiftPM removed the `swiftsoup` pin, because no package needs it now. That is not a family pin.
    - Discovery, not from this change: when the library compiles again, `EventProjection.swift` gives the warning "switch must be exhaustive" (missing case `.generationCall(_)`), and `SkillOutputProtectionTests.swift` gives the same warning. The pinned Router has that new `SessionEvent` case. Card 01M3A31FK1NS40GHFH8TZ867GZ (adopt the new Router request events) is where it belongs.
  timestamp: 2026-09-28T21:56:20.791425+00:00
- actor: claude-code
  id: 01m3n0a1t59kz634e4tcd4bxm7
  text: |-
    ### implement — changed
    - evidence: 3 files — Package.swift (modified), Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift (new), Tests/FoundationModelsACPAgentTests/ACPAgentTelemetryTests.swift (new). `swift build --build-tests` exit 0; `swift test --filter ACPAgentTelemetryTests` 3 tests pass; `swift test` 587 tests pass. Family pins in Package.resolved did not move.
    - next: review
  timestamp: 2026-09-28T21:56:33.221122+00:00
- actor: claude-code
  id: 01m3n18de3dfdn25kz5adgp2ax
  text: |-
    Iteration to remove the 2 compiler warnings that the /test step reported (red).

    - `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift`: `project(_:)` now has an explicit `case .generationCall:` arm. It sends no wire update, the same as the `@unknown default` arm. The `turnEnded` sum already counts the tokens of each generation call. The doc comment of `project(_:)` now says that the full projection of the Router request events is the scope of card ^tz867gz. I did not adopt other new Router API. In the same file, "fifteen" became "sixteen" in the type doc and in the MARK, because the pinned Router `SessionEvent` now has 16 cases. The other switches in the file (`RecordedEntryKind`, `OperationOutcome`, Router `ToolCallStatus`, `SegmentPayload`, `FileChange.kind`) did not warn.
    - `Tests/FoundationModelsACPAgentTests/SkillOutputProtectionTests.swift`: `text(of:)` now has `case .attachment: nil`, the same result as the `@unknown default` arm for other non-text segments. The doc comment says that an attachment segment adds no text. This is the only switch in the file.
    - No new test: the change keeps the behavior that the `@unknown default` arm had, and a test for `.generationCall` needs the `GenerationCallUsage` initializer, which is new Router API that this iteration must not adopt.
    - Verification: `swift package clean` then `swift build --build-tests`: build complete, 0 warnings from `Sources/` or `Tests/` of this package (0 `.swift:line:col: warning` lines in the log). The other warnings in the log are not from this project: 118 SwiftPM "failed loading/storing cached manifest ... disk I/O error" lines (the global manifest cache), 1 "missing creator for mutated node" for the mlx-swift Cmlx bundle, and 4 `-Wc++17-extensions` lines in the mlx-swift checkout. `swift test`: 587 tests in 64 suites pass, 1 known issue (HarnessSmokeTests, from before this change).
    - I did not run `swift package update`. `Package.resolved` did not change in this iteration. No commit, no push.
  timestamp: 2026-09-28T22:13:08.163072+00:00
- actor: claude-code
  id: 01m3n18f9cv7ndnk25fac64m2t
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Tests/FoundationModelsACPAgentTests/SkillOutputProtectionTests.swift. Clean `swift build --build-tests`: 0 warnings from project sources. `swift test`: 587 tests pass (1 known issue from before this change).
    - next: test
  timestamp: 2026-09-28T22:13:10.060030+00:00
- actor: claude-code
  id: 01m3n1s0kdb4zvdb85qeeq396j
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 118bb6e). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 5 files reviewed. 6 .kanban files not reviewed (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-09-28T22:22:12.077297+00:00
- actor: claude-code
  id: 01m3n1sj19xe50f4kffdjp2xa3
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Package.swift, Telemetry/ACPAgentTelemetry.swift, ACPAgentTelemetryTests.swift; then EventProjection.swift and SkillOutputProtectionTests.swift to remove 2 warnings
    - test: red (2 warnings), then green — swift test, 587 tests in 64 suites, 0 project warnings
    - commit: 118bb6e
    - review: clean — 0 findings; the task is in done
  timestamp: 2026-09-28T22:22:29.929908+00:00
position_column: done
position_ordinal: e880
title: 'OTel 1: add the ACPAgentTelemetry vocabulary file and the telemetry API products'
---
## What
Make the one vocabulary file of this package, the same shape as `FoundationModelsRouter/Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`. The other OTel tasks on this board use it. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md` (items 1, 3, 4).

- [x] In `Package.swift`, add the API-only products to the library target `FoundationModelsACPAgent`: `Tracing` (`swift-distributed-tracing`), `Logging` (`swift-log`), `Metrics` (`swift-metrics`). Declare the packages with the same version floors that FoundationModelsRouter and FoundationModelsExtras use (Extras card ^65xmgkv, 01M3MN838VZ4QX57C3965XMGKV, adds swift-log and swift-metrics there). `swift-distributed-tracing` and `swift-log` are already in `Package.resolved` through Router. Do NOT add `swift-otel` to the library target.
- [x] Do not add telemetry test products here. OTel 3 adds the FoundationModelsExtras `TelemetryTestSupport` product to the test target, and the later OTel tests use its `TelemetryCapture`.
- [x] Create `Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift` with `enum ACPAgentTelemetry` and these nested enums:
  - `SpanName` — prefix `FoundationModelsACPAgent.`: `initialize`, `sessionNew`, `sessionResume`, `prompt`, `cancel`, `command`, `elicitation`, `mcpConnect`.
  - `AttributeKey` — `acp.method`, `session.id`, `prompt.stop_reason`, `command.name`, `command.kind`, `elicitation.mode`, `elicitation.outcome`, `mcp.server.name`, `mcp.server.transport`, `error.type`.
  - `MetricName` — prefix `foundation_models_acp_agent.`: `prompts`, `prompt_duration`, `active_sessions`, `commands`, `mcp_connect_failures`.
  - `MetricDimension` — `stop_reason`, `command.kind`, `outcome`, `transport`.
  - `LogMetadataKey` — the identifier keys that log metadata uses (`session.id`, `acp.method`, `command.name`, `mcp.server.name`, `elicitation.mode`).
  - `static func tracer(explicit: (any Tracer)?) -> any Tracer`, the resolve-late rule of `RouterTracing.tracer(explicit:)`.
- [x] Write the "No content" rule in the doc comment, as `RouterTracing` does: no prompt text, response text, tool arguments, tool output or file content in a span attribute, a log message, a log metadata value or a metric dimension. Identifiers, names, counts and sizes are safe.

## Acceptance Criteria
- [x] `swift build` compiles the library with `import Tracing`, `import Logging` and `import Metrics` available, and the library target has no `swift-otel` dependency.
- [x] Each span name starts with `FoundationModelsACPAgent.` and each metric name starts with `foundation_models_acp_agent.`.
- [x] No span name or metric name is written two times: a test reads all the names and finds no duplicate.

## Tests
- [x] Add `Tests/FoundationModelsACPAgentTests/ACPAgentTelemetryTests.swift`: one case checks the span-name prefix, one checks the metric-name prefix, one checks that the names are unique.
- [x] Run `swift test --filter ACPAgentTelemetryTests`. Expected: all cases pass.
- [x] Run `swift build`. Expected: no error and no new warning.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel