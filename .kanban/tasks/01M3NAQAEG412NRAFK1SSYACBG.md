---
assignees:
- claude-code
depends_on:
- 01M3MNNAQ6YMAM4T4E9RM6R3RH
position_column: todo
position_ordinal: '9880'
title: 'OTel 2d: flush OTel on SIGTERM outside the ACP serve window (run mode, acp composition)'
---
## What
OTel 2b (^rm6r3rh) added `Sources/acp-agent/TerminationHandler.swift`. It watches `SIGTERM` only in the ACP serve window of `acp-agent acp`: from the start of `composed.serve(...)` to the end of stdin. In that window a `SIGTERM` closes the ACP connection, flushes the telemetry through `TelemetryBootstrap.shutdown()`, and exits 143.

Outside that window `SIGTERM` keeps its default action, and the last OTLP batch is lost:
- `acp-agent run` (the whole process: composition, prompt, answer).
- The composition window of `acp-agent acp` (configuration load, model download, model load), before the wire opens.
- `config`, `instructions` and `doctor`.

## Work
- [ ] Decide the reaction of `SIGTERM` in each window. For `run`: the prompt has an in-process ACP connection and a session, so `SIGTERM` can send `session/cancel` as the first `Ctrl-C` does, or it can close the connection. For the composition window: cancel the composition task as `InterruptibleComposition` does for the first `Ctrl-C`.
- [ ] Use the `TerminationHandler.Installer` shape, so unit tests give a scripted watch and never arm a process-wide signal.
- [ ] Each window exits 143 (`TerminationHandler.signalEndExitCode`) through the failure path of `AcpAgentCommand.main()`, which calls `TelemetryBootstrap.shutdown()`.
- [ ] Update the doc comment of `TelemetryBootstrap`, which lists `SIGTERM` outside the ACP serve window as an exit path that does not flush.

## Tests
- [ ] Unit: a scripted `SIGTERM` in each new window gives exit code 143 and runs the close or the cancel.
- [ ] Integration: add cases to `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryFlushTests.swift` for `SIGTERM` during a paced `run` prompt: exit 143, and at least one span whose name starts with `FoundationModelsRouter.` reaches `OTLPTestReceiver`. With no receiver on the port, the process ends in less than 5 seconds.
- [ ] Run `swift test` and `swift test --package-path IntegrationTests`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel