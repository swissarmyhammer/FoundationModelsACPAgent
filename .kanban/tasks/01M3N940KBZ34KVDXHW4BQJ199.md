---
depends_on:
- 01M3MNNAQ6YMAM4T4E9RM6R3RH
position_column: todo
position_ordinal: '9780'
title: 'OTel 2c: bootstrap logging one time, and obey OTEL_SDK_DISABLED, in acp-agent'
---
## What
The FoundationModelsACPClient session found three facts about swift-otel 1.5.1 that affect `Sources/acp-agent/TelemetryBootstrap.swift` (OTel 2 ^vvjxe66, commit 988a354). This task follows OTel 2b ^rm6r3rh, which changes the same file.

1. `OTel.bootstrap` can bootstrap logs and then fail on metrics or traces. A second `LoggingSystem.bootstrap` stops the process. Now `bootstrap(environment:)` calls `OTel.bootstrap` for traces, logs and metrics together, so a failure can leave logging half set up. ACPClient uses `OTel.makeLoggingBackend` and one `LoggingSystem.bootstrap`, and calls `OTel.bootstrap` for traces and metrics only.
2. `OTEL_SDK_DISABLED` must be checked, without case sensitivity, before the bootstrap. When it is `true`, use the stderr handler and no-op tracing and metrics, the same as when `OTEL_EXPORTER_OTLP_ENDPOINT` is not set.
3. Correction of a reason: the default swift-log handler writes to stderr (`StreamLogHandler.standardError`, swift-log `LoggingSystem.swift`), not to stdout. The bootstrap and the stdout test stay necessary. Correct each doc comment that gives stdout as the reason.

Work:
- [ ] In `Sources/acp-agent/TelemetryBootstrap.swift`: make the logging backend with `OTel.makeLoggingBackend` (or the swift-otel 1.5.1 API with that job), call `LoggingSystem.bootstrap` exactly one time on every path, and call `OTel.bootstrap` for traces and metrics only (logs off in its configuration).
- [ ] If the logging backend cannot be made, bootstrap the stderr handler one time. If the traces and metrics bootstrap fails, logging stays as it is, and the reason goes to stderr.
- [ ] Check `OTEL_SDK_DISABLED` without case sensitivity before any bootstrap.
- [ ] Correct the doc comments about the default handler (item 3).

## Acceptance Criteria
- [ ] No path of `bootstrap(environment:)` calls `LoggingSystem.bootstrap` two times.
- [ ] With `OTEL_EXPORTER_OTLP_ENDPOINT` set and a traces or metrics configuration that fails (for example an unknown `OTEL_TRACES_EXPORTER` value), `acp-agent acp` does not crash, answers `initialize`, and stdout has only ACP frames.
- [ ] With `OTEL_SDK_DISABLED=TRUE` (and `true`) and an endpoint set, the agent sends nothing to the endpoint.
- [ ] No doc comment says that the default swift-log handler writes to stdout.

## Tests
- [ ] Add cases to `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift`: a failing traces configuration (no crash, good `initialize`, stdout only ACP frames), and `OTEL_SDK_DISABLED=TRUE` with the local OTLP test receiver of OTel 2b (the receiver gets no request).
- [ ] Run `swift test --package-path IntegrationTests --filter "TelemetryStdoutTests|TelemetryFlushTests"`. Expected: pass.
- [ ] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel