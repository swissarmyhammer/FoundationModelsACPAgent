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
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
position_column: doing
position_ordinal: '80'
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