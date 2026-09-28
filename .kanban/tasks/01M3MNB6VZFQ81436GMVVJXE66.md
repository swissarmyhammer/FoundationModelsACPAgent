---
assignees:
- claude-code
depends_on:
- 01M3MNAKQT4H82BNG84PE7PD6X
position_column: todo
position_ordinal: 8c80
title: 'OTel 2: bootstrap swift-otel in acp-agent, and keep stdout for ACP only'
---
## What
Only the executable depends on `swift-otel` (design item 1). The default swift-log handler writes to stdout, but `acp-agent acp` uses stdout for ACP frames. So `acp-agent` must always bootstrap logging before it writes a log record (design item 6). Approved design: `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`.

- [ ] In `Package.swift`, add the `swift-otel` package and its `OTel` product to the `acp-agent` executable target only. Do not add it to the library target, to `acp-print`, or to the test-support target.
- [ ] Create `Sources/acp-agent/TelemetryBootstrap.swift` with `enum TelemetryBootstrap` and `static func bootstrap(environment: [String: String])`:
  - When `OTEL_EXPORTER_OTLP_ENDPOINT` is set: call `OTel.bootstrap` for traces, logs and metrics. The standard `OTEL_*` variables configure it. Keep the returned service and run it for the life of the process, and shut it down (flush) before the process exits.
  - When it is not set: bootstrap `LoggingSystem` with `StreamLogHandler.standardError`, and leave tracing and metrics as no-op.
  - Call it one time, as the first statement of `AcpAgentCommand.main()` in `Sources/acp-agent/AcpAgentCommand.swift`, before `parseAsRoot()`.
- [ ] Keep the `logger: .standardError` argument of `composed.serve(over:logger:)` in `Sources/acp-agent/AcpCommand.swift`.

- [ ] The unit test target `FoundationModelsACPAgentTests` links the `acp-agent` target. So only `AcpAgentCommand.main()` calls `TelemetryBootstrap.bootstrap`. No test in process may call it: it calls `LoggingSystem.bootstrap`, and the FoundationModelsExtras `TelemetryCapture` (used by OTel 3 and later) requires that the test process never bootstraps logging itself. Test `TelemetryBootstrap` only in the spawned-process tests of `IntegrationTests`.

## Acceptance Criteria
- [ ] `acp-agent acp` with no `OTEL_*` variable writes only JSON-RPC ndJSON frames to stdout during initialize, session/new and one prompt.
- [ ] A log record from the library goes to stderr when no OTLP endpoint is set.
- [ ] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to an address with no listener, `acp-agent acp` still starts and answers `initialize`, and stdout still has only ACP frames.
- [ ] `swift package show-dependencies` shows `swift-otel` only under the `acp-agent` target.

## Tests
- [ ] Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift`. Spawn the built `acp-agent acp` with `TierThreeFixture.stubModelEnvironment` and with every `OTEL_*` variable removed from the environment. Wrap the transport in `InboundTapTransport` (from `StdioContractTests.swift`), run initialize, session/new and one prompt, and assert that each stdout line parses as a JSON object with `"jsonrpc": "2.0"` (the same check as `StdioContractTests.assertFramesArePureJSONRPC`). Move that assertion to a shared helper under `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/` so the two suites use one copy.
- [ ] Add a second case in the same file with `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1` (no listener). Assert the same stdout rule and a good `initialize` response.
- [ ] Run `swift test --package-path IntegrationTests --filter TelemetryStdoutTests`. Expected: both cases pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel