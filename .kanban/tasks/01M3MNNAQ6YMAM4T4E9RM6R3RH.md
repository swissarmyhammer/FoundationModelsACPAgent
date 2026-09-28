---
depends_on:
- 01M3MNB6VZFQ81436GMVVJXE66
position_column: todo
position_ordinal: '9580'
title: 'OTel 2b: flush OTel on each exit path of acp-agent (end of stdin, errors, SIGINT, SIGTERM)'
---
## What
An OTLP batch exporter keeps spans, log records and metrics in memory and sends them later. When the process calls `exit()` or a signal ends it, the last batch is lost. The FoundationModelsACPClient session found this (their task ^0dgfv7k). So `acp-agent` must shut down OTel (flush traces, logs and metrics) on each exit path. This task follows OTel 2 (^vvjxe66), which adds `Sources/acp-agent/TelemetryBootstrap.swift`.

The exit paths of `acp-agent` now:
- Normal return from `AcpAgentCommand.main()` in `Sources/acp-agent/AcpAgentCommand.swift` (for example `acp` mode after the end of stdin, `run` after the answer).
- `exitAfterFailure(_:)` in the same file, which calls `Darwin.exit(outcome.code)`. The first `SIGINT` (exit 4) and each error come here.
- The second `SIGINT` in `Sources/acp-agent/InterruptHandler.swift`, which calls `Darwin._exit(AgentExitCode.cancelled.rawValue)`. Its contract is "end at once" (cli-plan.md §5.9).
- `SIGTERM`: there is no handler now, so the default action ends the process.

Work:
- [ ] Give `TelemetryBootstrap` one `static func shutdown() async` that flushes and shuts down the OTel service, with a fixed deadline (for example 2 seconds), so a dead collector cannot hold the process. When OTel is not bootstrapped (no `OTEL_EXPORTER_OTLP_ENDPOINT`), it does nothing.
- [ ] Call `shutdown()` before the normal return of `main()` and before `Darwin.exit` in `exitAfterFailure(_:)`.
- [ ] Add a `SIGTERM` watch (a `DispatchSourceSignal`, the same shape as `InterruptHandler.onSIGINT`). On `SIGTERM`: close the ACP connection, call `shutdown()`, then exit with the code for a signal end. Put it in `Sources/acp-agent/InterruptHandler.swift` or in a new `Sources/acp-agent/TerminationHandler.swift`.
- [ ] Keep the second-`SIGINT` `_exit` as it is: the user asked to end at once, and a flush can wait on the network. Write this limit in the doc comment of `TelemetryBootstrap`.

## Acceptance Criteria
- [ ] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to a local test receiver and a long batch delay (`OTEL_BSP_SCHEDULE_DELAY=600000`, so only the shutdown flush can send), the last span of the run gets to the receiver on each of these paths: end of stdin in `acp` mode, the first `SIGINT` during a `run` turn (exit 4), and `SIGTERM` in `acp` mode after one prompt.
- [ ] With the receiver stopped (nothing listens on the port), each of these paths ends in less than 5 seconds, with its usual exit code.
- [ ] With no `OTEL_*` variable, the exit codes and stdout stay as before (the existing `CLIProcessTests`, `InterruptTests` and `TelemetryStdoutTests` pass).

## Tests
- [ ] Add a small OTLP/HTTP receiver in `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/OTLPTestReceiver.swift` (an `NWListener` on `127.0.0.1` that records each request body). Use the OTLP protocol that swift-otel supports for HTTP; if it supports `http/json`, set `OTEL_EXPORTER_OTLP_PROTOCOL=http/json` so the test can read the span names.
- [ ] Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryFlushTests.swift` with one case for each exit path above. Use `TierThreeFixture.stubModelEnvironment` and the paced stub of `InterruptTests.swift` for the `SIGINT` case. Assert that the receiver got a span named `FoundationModelsRouter.submission` (a Router span, so this task does not wait for OTel 6).
- [ ] Add one case with no receiver on the port, and assert the exit time and the exit code.
- [ ] Run `swift test --package-path IntegrationTests --filter TelemetryFlushTests`. Expected: pass.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel