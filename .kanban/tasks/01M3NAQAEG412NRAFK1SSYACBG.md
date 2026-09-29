---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3ne8zyw96g7s128cna3cwyy
  text: |-
    Research done. Findings:
    - `InterruptibleComposition.run` is the one composition window of `acp` and of in-process `run`. `RunPrompt.send` is the one prompt window of in-process and out-of-process `run`.
    - `ClientSideConnection.request` throws `CancellationError` on task cancel and sends `$/cancel_request`. So a "cancel the whole run task" design would not send `session/cancel`, and the Router span end is not sure. Decision: explicit windows, as the card says.
    - Decision for each window: composition window: the first SIGTERM cancels the composition task. Prompt window: the first SIGTERM sends `session/cancel`, as the first Ctrl-C does. After the window ends, it throws `TerminationHandler.signalEnd` (143). A later SIGTERM in the window is ignored.
    - `config` and `instructions` are synchronous `ParsableCommand`s: no task to cancel, no model, no connection, no Router session. `doctor` holds no Router session either. These keep the default SIGTERM action; the `TelemetryBootstrap` doc comment states it.
    - Short gaps with the default action stay: the stdin read of the prompt text, and the in-process handshake and session open, and the out-of-process handshake window (the child composition).
    Plan: add `TerminationHandler.unwatched` and a helper `TerminationHandler.run(watchedBy:stoppingWith:_:)`; thread a `terminatedBy` installer through `InterruptibleComposition.run`, `RunPrompt.answer/send`, `Run.perform`, `OutOfProcessPrompt.answer`; `SignalledExecutableRun` gets a signal number parameter for the integration case.
  timestamp: 2026-09-29T02:00:38.620849+00:00
- actor: claude-code
  id: 01m3nf4j89dzpr440xxz6axtz8
  text: |-
    Implementation landed (not committed).
    - New `TerminationHandler.run(watchedBy:stoppingWith:_:)`: arms the SIGTERM watch for one window. The first arrival runs the stop of the window. When the work ends after an arrival, the window throws `signalEnd` (143), and the failure path of `main()` flushes. A later SIGTERM in the window is ignored (the watch stands). New `TerminationHandler.unwatched` is the default installer.
    - Composition window (`InterruptibleComposition.run(interruptedBy:terminatedBy:_:)`): SIGTERM cancels the composition task. `acp` passes `onSIGTERM`; in-process `run` too.
    - Prompt window (`RunPrompt.send(...terminatedBy:)`): SIGTERM sends `session/cancel`, the same stop as the first Ctrl-C (one private `cancel(_:over:)` for both). The out-of-process handshake reaps the child on SIGTERM.
    - `OutOfProcessPrompt.InterruptFlag` moved to a shared `ArrivalFlag` (Sources/acp-agent/ArrivalFlag.swift), used by both windows.
    - `config`, `instructions`, `doctor`, the prompt-text read and the short wire open keep the default SIGTERM action; `TelemetryBootstrap` and `TerminationHandler` doc comments state this.
    - Tests: TDD RED was the compile failure of the new API. Unit: TerminationHandlerTests (+3), CompositionInterruptTests (+2), ScriptedInterruptWatch support now has one `ScriptedArrival` builder for SIGINT and SIGTERM watches. Integration: `SignalledExecutableRun` takes `signalNumber` (default SIGINT, now sent with `kill`); TelemetryFlushTests gets the `runTermination` path (live receiver case, and the no-receiver < 5 s case through `allCases`).
    - Second-SIGINT `_exit` is unchanged. No `Package.resolved` pin moved.
    Note: SwiftPM prints "failed loading cached manifest ... disk I/O error" and "missing creator for mutated node" warnings; these come from the SwiftPM cache and build system (the disk is 99% full), not from project sources.
  timestamp: 2026-09-29T02:15:42.089723+00:00
- actor: claude-code
  id: 01m3nf4n1jvs7hzdyq58gye6sn
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/acp-agent/{ArrivalFlag.swift (new), TerminationHandler.swift, InterruptibleComposition.swift, RunPrompt.swift, RunCommand.swift, AcpCommand.swift, OutOfProcessPrompt.swift, TelemetryBootstrap.swift}; Tests/FoundationModelsACPAgentTests/{TerminationHandlerTests.swift, CompositionInterruptTests.swift, Support/ScriptedInterruptWatch.swift}; IntegrationTests/.../{TelemetryFlushTests.swift, Support/SignalledExecutableRun.swift}. `swift test`: 602 tests in 68 suites passed (1 known issue, earlier). `swift test --package-path IntegrationTests`: 25 tests in 10 suites passed. No warning from project sources.
    - next: review
  timestamp: 2026-09-29T02:15:44.946738+00:00
depends_on:
- 01M3MNNAQ6YMAM4T4E9RM6R3RH
position_column: doing
position_ordinal: '8180'
title: 'OTel 2d: flush OTel on SIGTERM outside the ACP serve window (run mode, acp composition)'
---
## What
OTel 2b (^rm6r3rh) added `Sources/acp-agent/TerminationHandler.swift`. It watches `SIGTERM` only in the ACP serve window of `acp-agent acp`: from the start of `composed.serve(...)` to the end of stdin. In that window a `SIGTERM` closes the ACP connection, flushes the telemetry through `TelemetryBootstrap.shutdown()`, and exits 143.

Outside that window `SIGTERM` keeps its default action, and the last OTLP batch is lost:
- `acp-agent run` (the whole process: composition, prompt, answer).
- The composition window of `acp-agent acp` (configuration load, model download, model load), before the wire opens.
- `config`, `instructions` and `doctor`.

## Work
- [x] Decide the reaction of `SIGTERM` in each window. For `run`: the prompt has an in-process ACP connection and a session, so `SIGTERM` can send `session/cancel` as the first `Ctrl-C` does, or it can close the connection. For the composition window: cancel the composition task as `InterruptibleComposition` does for the first `Ctrl-C`.
- [x] Use the `TerminationHandler.Installer` shape, so unit tests give a scripted watch and never arm a process-wide signal.
- [x] Each window exits 143 (`TerminationHandler.signalEndExitCode`) through the failure path of `AcpAgentCommand.main()`, which calls `TelemetryBootstrap.shutdown()`.
- [x] Update the doc comment of `TelemetryBootstrap`, which lists `SIGTERM` outside the ACP serve window as an exit path that does not flush.

## Tests
- [x] Unit: a scripted `SIGTERM` in each new window gives exit code 143 and runs the close or the cancel.
- [x] Integration: add cases to `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryFlushTests.swift` for `SIGTERM` during a paced `run` prompt: exit 143, and at least one span whose name starts with `FoundationModelsRouter.` reaches `OTLPTestReceiver`. With no receiver on the port, the process ends in less than 5 seconds.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel