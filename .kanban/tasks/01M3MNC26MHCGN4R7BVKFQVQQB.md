---
assignees:
- claude-code
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
position_column: todo
position_ordinal: 8d80
title: 'OTel 3: replace os.Logger with swift-log in the session surface (Session, PromptTurn, Initialization, SessionResume)'
---
## What
Design item 2: remove all `os.Logger` use and use `Logging.Logger` (swift-log). This task changes the first 4 of the 11 `os.Logger` sites. OTel 4 and OTel 5 change the other 7. This task also adds the Extras test helper that the later OTel tasks use. Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

Extras: FoundationModelsExtras OTel A to D are on Extras origin/main (HEAD 70ad74d, 2026-09-28). Run `swift package update FoundationModelsExtras` before you start this task.

Sites:
- [ ] `Sources/FoundationModelsACPAgent/RoutedACPAgent.swift` — `sessionLogger` (category `Session`).
- [ ] `Sources/FoundationModelsACPAgent/Agent/TurnState.swift` — `turnLogger` (category `PromptTurn`). `PromptTurn.swift` and other files call it; change the call sites too.
- [ ] `Sources/FoundationModelsACPAgent/Agent/Initialization.swift` — `initializationLogger`.
- [ ] `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` — `resumeLogger`.
- [ ] In `Package.swift`, add the FoundationModelsExtras `TelemetryTestSupport` product (Extras card ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G) to the test target `FoundationModelsACPAgentTests` only.

Rules for each site:
- Replace `import os` with `import Logging`. The label is `"FoundationModelsACPAgent.<Category>"`, with the same category name as now.
- Do not keep the logger as a global `let` or a `static let`. A logger made before a `TelemetryCapture` starts does not go to the capture (Extras fact). Make the `Logger` at the call, or as a stored property that the instance makes in its `init`.
- Keep the level: `debug` → `.debug`, `info` → `.info`, `notice` → `.notice`, `warning`/`error` → the same level, `fault` → `.critical`.
- Move each interpolated identifier (session id, method name, command name) into log metadata, with a key from `ACPAgentTelemetry.LogMetadataKey` (OTel 1). The message is a fixed string.
- No content rule (design item 4): a log message or metadata value must not hold prompt text, response text, tool arguments, tool output or file content. Where a site logs such a value now, log its size or kind in its place.
- The "turn" to "prompt" rename cards (01M3A32E8EVDZ16ZQ8QF9513F2) can change the names `turnLogger` and `TurnState`. Use the names that are in the code when you do this task.

## Acceptance Criteria
- [ ] The 4 files have no `import os`, no `os.Logger`, and no global or `static let` logger.
- [ ] Each changed log call has a fixed message string and puts identifiers in metadata.
- [ ] An ignored `session/cancel` for an unknown session writes one `.notice` record with the label `FoundationModelsACPAgent.PromptTurn` and the session id in metadata.

## Tests
- [ ] Test rules for all OTel tasks on this board: use `TelemetryCapture` from `TelemetryTestSupport`. It uses task-local `withTracer` and `withMetricsFactory`, and it bootstraps logging one time. Never call `LoggingSystem.bootstrap`, `InstrumentationSystem.bootstrap` or `MetricsSystem.bootstrap` in the test process. Make the agent and the harness inside the capture.
- [ ] Add `Tests/FoundationModelsACPAgentTests/SessionSurfaceLoggingTests.swift`: in a capture, send `session/cancel` for an unknown session through the harness in `Tests/FoundationModelsACPAgentTestSupport/Harness.swift`, and assert the captured record (label, level, `session.id` metadata).
- [ ] Run `swift test --filter SessionSurfaceLoggingTests`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel