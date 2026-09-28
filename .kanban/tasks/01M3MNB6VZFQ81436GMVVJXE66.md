---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n5de3spth9gmtgnbcrv705
  text: |-
    Research and tests first:
    - swift-otel 1.5.1 is the newest tag. Its manifest is tools 6.1, product `OTel`, default traits OTLPHTTP and OTLPGRPC. It adds swift-service-lifecycle, grpc-swift-2, async-http-client, swift-protobuf, swift-nio-ssl and more.
    - `OTel.bootstrap(configuration:environment:)` returns `some Service`. It must run in a `ServiceGroup`. Its diagnostic logger (`.console`) writes to stderr (`StreamLogHandler.standardError`). Only the `console` exporters (OTEL_TRACES_EXPORTER=console and the like) call `print` and write to stdout. The card does not ask to block that choice.
    - `AgentProcess` of the client package takes no environment: the child gets the environment of the test process. So `TelemetryStdoutTests` starts the agent through `/usr/bin/env -u OTEL_... KEY=VALUE ... acp-agent acp`, and the test process environment does not change.
    - The waitForIdle helper and the frame assertion moved to `Support/StdoutFrameChecks.swift`, so `StdioContractTests` and `TelemetryStdoutTests` use one copy.
    - The IntegrationTests Package.resolved had family pins different from the root (Router d469aa0, Extras 55d6b04 and others). I copied the root Package.resolved into it, so the family pins are equal now.
    - RED: both new cases PASS before the bootstrap exists (0.86 s and 0.50 s). This is expected: they are regression guards on the stdout rule. No code writes to stdout today, and without the bootstrap the OTEL variable has no effect.
  timestamp: 2026-09-28T23:25:47.001102+00:00
- actor: claude-code
  id: 01m3n6ktf9e2r702s6yqyj2k8b
  text: |-
    Implementation landed:
    - Package.swift: swift-otel from 1.5.1 (product `OTel`) is on the `acp-agent` target only. The target also links `ServiceLifecycle` (swift-service-lifecycle from 2.4.1, which swift-otel already declares) and `Logging`. The reason: the OTel service must run in a `ServiceGroup`, and a direct `import` needs a declared product. A new `loggingProduct` constant is shared with `telemetryAPIProducts`.
    - `Sources/acp-agent/TelemetryBootstrap.swift`: `bootstrap(environment:)` and `shutdown()`. With the endpoint set: `OTel.bootstrap(environment:)`, then a `ServiceGroup` that runs in a stored task. If `OTel.bootstrap` throws, the reason goes to a stderr logger and the swift-log default handler (stderr) stays. Without the endpoint: `LoggingSystem.bootstrap(StreamLogHandler.standardError)`.
    - `AcpAgentCommand.main()`: the bootstrap is the first statement, and `await TelemetryBootstrap.shutdown()` runs after a normal return. `exitAfterFailure`, SIGINT and SIGTERM are not flushed here: that is ^rm6r3rh (OTel 2b), which also adds the flush deadline.
    - Package.resolved: only NEW pins (swift-otel, swift-service-lifecycle, grpc-swift-2, async-http-client, swift-protobuf, swift-nio-ssl and others). No existing pin moved: Router bbad3ce, Extras 0dc42cf. IntegrationTests/Package.resolved is a copy of the root one, so the family pins are equal.
    - `swift package show-dependencies` shows swift-otel 1.5.1 at the package level. That command does not show targets. The manifest adds `otelProduct` to the `acp-agent` target only.
    - Not changed: OTEL_SERVICE_NAME has no default in code, so the service name is `unknown_service` unless the variable is set. With OTEL_*_EXPORTER=console, swift-otel prints to stdout, and that breaks `acp` mode. The card did not ask for a guard against that.
    - The build shows one build-system warning about `mlx-swift_Cmlx.bundle` ("missing creator for mutated node"). It comes from the mlx dependency, not from the sources of this project.
  timestamp: 2026-09-28T23:46:44.841578+00:00
- actor: claude-code
  id: 01m3n6kxxzvy2f79gxvzdyfe4f
  text: |-
    ### implement — changed
    - evidence: 6 files: Package.swift, Sources/acp-agent/TelemetryBootstrap.swift (new), Sources/acp-agent/AcpAgentCommand.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift (new), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/StdoutFrameChecks.swift (new), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/StdioContractTests.swift. Also local untracked Package.resolved (root and IntegrationTests). `swift build`: 0 warnings from project sources. `swift test`: 591 tests in 66 suites passed (1 known issue that was there before). `swift test --package-path IntegrationTests`: 20 tests in 9 suites passed, TelemetryStdoutTests 2/2 included.
    - next: review
  timestamp: 2026-09-28T23:46:48.383948+00:00
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
position_column: doing
position_ordinal: '8180'
title: 'OTel 2: bootstrap swift-otel in acp-agent, and keep stdout for ACP only'
---
## What
Only the executable depends on `swift-otel` (design item 1). The default swift-log handler writes to stdout, but `acp-agent acp` uses stdout for ACP frames. So `acp-agent` must always bootstrap logging before it writes a log record (design item 6). Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

- [x] In `Package.swift`, add the `swift-otel` package and its `OTel` product to the `acp-agent` executable target only. Do not add it to the library target, to `acp-print`, or to the test-support target.
- [x] Create `Sources/acp-agent/TelemetryBootstrap.swift` with `enum TelemetryBootstrap` and `static func bootstrap(environment: [String: String])`:
  - When `OTEL_EXPORTER_OTLP_ENDPOINT` is set: call `OTel.bootstrap` for traces, logs and metrics. The standard `OTEL_*` variables configure it. Keep the returned service and run it for the life of the process, and shut it down (flush) before the process exits.
  - When it is not set: bootstrap `LoggingSystem` with `StreamLogHandler.standardError`, and leave tracing and metrics as no-op.
  - Call it one time, as the first statement of `AcpAgentCommand.main()` in `Sources/acp-agent/AcpAgentCommand.swift`, before `parseAsRoot()`.
- [x] Keep the `logger: .standardError` argument of `composed.serve(over:logger:)` in `Sources/acp-agent/AcpCommand.swift`.

- [x] The unit test target `FoundationModelsACPAgentTests` links the `acp-agent` target. So only `AcpAgentCommand.main()` calls `TelemetryBootstrap.bootstrap`. No test in process may call it: it calls `LoggingSystem.bootstrap`, and the FoundationModelsExtras `TelemetryCapture` (used by OTel 3 and later) requires that the test process never bootstraps logging itself. Test `TelemetryBootstrap` only in the spawned-process tests of `IntegrationTests`.

## Acceptance Criteria
- [x] `acp-agent acp` with no `OTEL_*` variable writes only JSON-RPC ndJSON frames to stdout during initialize, session/new and one prompt.
- [x] A log record from the library goes to stderr when no OTLP endpoint is set.
- [x] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to an address with no listener, `acp-agent acp` still starts and answers `initialize`, and stdout still has only ACP frames.
- [x] `swift package show-dependencies` shows `swift-otel` only under the `acp-agent` target.

## Tests
- [x] Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift`. Spawn the built `acp-agent acp` with `TierThreeFixture.stubModelEnvironment` and with every `OTEL_*` variable removed from the environment. Wrap the transport in `InboundTapTransport` (from `StdioContractTests.swift`), run initialize, session/new and one prompt, and assert that each stdout line parses as a JSON object with `"jsonrpc": "2.0"` (the same check as `StdioContractTests.assertFramesArePureJSONRPC`). Move that assertion to a shared helper under `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/` so the two suites use one copy.
- [x] Add a second case in the same file with `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1` (no listener). Assert the same stdout rule and a good `initialize` response.
- [x] Run `swift test --package-path IntegrationTests --filter TelemetryStdoutTests`. Expected: both cases pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel