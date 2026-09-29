---
comments:
- actor: claude-code
  id: 01m3n7ea5txr310xs6exxtesbk
  text: |-
    Research results (before code):
    - swift-otel 1.5.1 supports `grpc`, `http/protobuf` and `http/json` (`OTel.Configuration.OTLPExporterConfiguration.Protocol`). With `http/json` the exporter sends `Content-Type: application/json`. The receiver must answer 2xx with `Content-Type: application/json` and a body such as `{}`, or with 204 and no content type. Other answers make the export fail.
    - `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_EXPORT_TIMEOUT`, `OTEL_BLRP_*` and `OTEL_METRIC_EXPORT_*` are read by swift-otel 1.5.1.
    - `OTelBatchSpanProcessor.run()` calls `forceFlush()` after a graceful shutdown, and `forceFlush()` is bounded by `exportTimeout` (default 30 s). So `TelemetryBootstrap.shutdown()` (added in ^vvjxe66) already flushes, but it has no deadline. The task still needs the deadline, the call in `exitAfterFailure(_:)`, and the SIGTERM watch.
    - The HTTP exporter retries only on 429/502/503/504. A refused connection fails at once.
  timestamp: 2026-09-29T00:01:12.890612+00:00
- actor: claude-code
  id: 01m3n7efe8g2q4rhe87xrdqadv
  text: |-
    BLOCKER: the span name in the Tests section does not exist in the pinned Router graph.
    - The card says: assert that the receiver got a span named `FoundationModelsRouter.submission`.
    - The root and IntegrationTests `Package.resolved` pin FoundationModelsRouter at `bbad3ce`. The orchestrator rule is: do not move a family pin.
    - At `bbad3ce`, `RouterTracing.SpanName` has `embed`, `turn`, `tool`, `compact`, `resolve`, `load`, `fork`, `session`. There is no `submission`. The span of one prompt is `FoundationModelsRouter.turn` (`RoutedSessionActorTurnExecution.swift`).
    - `static let submission = prefix + "submission"` comes in Router commit `c682155` (^x7cxsg3). That commit is not an ancestor of `bbad3ce`; `git log bbad3ce..c682155` has 47 commits.
    - So the acceptance check cannot pass with the pinned graph. Changing the asserted name is a change to a card decision, and moving the pin is forbidden. A person must decide one of these: (a) assert `FoundationModelsRouter.turn` while the pin stays at `bbad3ce`; (b) move the Router pin (needs the family main branches to build here); (c) wait for the pin move.
    - No source file or test file was changed.
  timestamp: 2026-09-29T00:01:18.280980+00:00
- actor: claude-code
  id: 01m3n7ehzanhjd1wvgd31mrpk6
  text: |-
    ### implement — stuck
    - evidence: no files changed. The span `FoundationModelsRouter.submission` that the card tells the test to assert is absent at the pinned Router `bbad3ce`; it starts at Router `c682155`, 47 commits later. The pinned Router emits `FoundationModelsRouter.turn` for the same unit.
    - next: a person chooses (a) assert `FoundationModelsRouter.turn`, (b) move the Router pin, or (c) wait. Then run implement again.
  timestamp: 2026-09-29T00:01:20.874630+00:00
- actor: claude-code
  id: 01m3n7f6r2hcxpvv9z5qaanhm2
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The card asserted the span FoundationModelsRouter.submission, which the pinned Router bbad3ce does not have (it has FoundationModelsRouter.turn).
    - test, commit, review: not run
    - next: the card author changed the Tests section: assert a span whose name starts with FoundationModelsRouter., not one exact name. Run implement again.
  timestamp: 2026-09-29T00:01:42.146442+00:00
- actor: claude-code
  id: 01m3n7r066dq01c0zskf5ean78
  text: |-
    Iteration 2 research (before code):
    - The pinned Router bbad3ce emits `FoundationModelsRouter.turn` (kind client) around each prompt, also for the stub model: `EchoModel.makeRouter` gives a real Router. So a span name with the prefix `FoundationModelsRouter.` is present on each path.
    - `AgentProcess` reaps the child itself and discards the exit status, and it cannot take an environment. `SubprocessTransport` (FoundationModelsACP) takes an environment and gives the status, but it has no way to close stdin without SIGTERM. So the acp-mode integration cases need their own spawn: a `Process` with an environment, stdin and stdout pipes, a stdin close, a SIGTERM, and the exit status. The environment of the child removes each `OTEL_*` variable of the test process, as `TelemetryStdoutTests` does.
    - The run-mode SIGINT case can use `SignalledExecutableRun` (it takes an environment and gives the exit code). Its `exitLimit` can carry the 5-second limit.
    - `service.task.value` does not react to cancellation. So the 2-second deadline of `shutdown()` must race the task end and a sleep through a stream, not through a task group (a task group waits for each child).
    - Decision: the exit code of a SIGTERM end is 143 (128 + SIGTERM, the shell convention for an end by a signal). It is not a row of the cli-plan.md §5.8 table (`ExitCodeTests` holds the row count), so it is a named constant of the new `TerminationHandler`.
    - Decision: the SIGTERM watch is armed for the ACP serve window of `acp` mode (the window that has the ACP connection to close), with the same Installer shape as `InterruptHandler`. Outside that window SIGTERM keeps its default action. A new task records the `run` mode and the composition window.
  timestamp: 2026-09-29T00:06:30.342701+00:00
- actor: claude-code
  id: 01m3nc75r4n8pz4nzhgdp53m2n
  text: |-
    Implementation landed (iteration 2).
    - `TelemetryBootstrap.shutdown()` now waits for the service for `shutdownDeadline` (2 seconds) at most, through `waitForEnd(of:within:)`: two unstructured tasks (the task end, a sleep) report into one stream, and the first report decides. It does not use a ServiceGroup graceful-shutdown timeout (those end in fatalError, per the FoundationModelsACPClient session). On the deadline it cancels the service task and writes one line to stderr.
    - `exitAfterFailure(_:)` is async and calls `shutdown()` after the message and before `exit(3)`.
    - New `Sources/acp-agent/TerminationHandler.swift`: `TerminationWatch` and `TerminationHandler` with the `Installer` shape of `InterruptHandler`. `Acp.run()` calls `TerminationHandler.serve(untilInboundEnd:closing:watchedBy:)`: it races the stdin end and the first SIGTERM, closes the ACP connection, and on SIGTERM throws `ExitCode(143)`, so the failure path of `main()` flushes and exits 143.
    - Doc comment of `TelemetryBootstrap` lists the exit paths and the two that do not flush (second Ctrl-C `_exit`, SIGTERM outside the ACP serve window). `InterruptHandler.endAtOnce()` notes the lost batch. The `_exit` stays.
    - Tests: `Tests/FoundationModelsACPAgentTests/TerminationHandlerTests.swift` and `TelemetryShutdownTests.swift` (6 unit cases). Integration: `Support/OTLPTestReceiver.swift` (NWListener, HTTP/1.1, Content-Length and chunked bodies, answers 200 + application/json + `{}`), `Support/SpawnedACPAgent.swift` (Process with its own environment, stdin close, SIGTERM, exit status), `TelemetryFlushTests.swift` (3 flush cases + 1 parameterized no-receiver case over the 3 paths; it asserts `didExit`, so a crash fails it).
    - RED proof: with the old sources, `theFirstInterruptFlushesTheLastSpans` and `aTerminationFlushesTheLastSpans` failed (no Router span; SIGTERM killed the process), and the no-receiver end-of-stdin case took more than 5 s: the flush to a refused endpoint held the process. So the "refused connection fails at once" note of iteration 1 is not true for the whole shutdown.

    What did not work, and why:
    - The first full integration runs hung for 30 minutes. `sample` of the test process: all 18 cooperative-pool threads were blocked in `readToEnd()` of `BuiltExecutableRun` (16) and `drain` of `SignalledExecutableRun` (2). `lsof`: the `acp-agent acp` children that `AgentProcess` spawns (StdioContractTests, TelemetryStdoutTests) held copies of those pipes, because `AgentProcess` uses `posix_spawn` and Foundation `Pipe` descriptors carry no FD_CLOEXEC. The same cause kept the stdin of my spawned agent open after the close. Fix: new `Support/PipeCloseOnExec.swift` (`Pipe.markCloseOnExec()`), used in `BuiltExecutableRun`, `SignalledExecutableRun`, `ProcessCensus` and `SpawnedACPAgent`. `SpawnedACPAgent` reads its pipes with readability handlers, not with blocking reads on the pool.
    - A live-receiver exit limit of 5 s flaked under the load of the other suites (5.8 s once). The live-receiver cases now use a 30 s limit; the no-receiver case keeps the 5 s of the card.
    - `SignalledExecutableRun` gained `inheritedEnvironment`, `didExit` and `exitWait`.
    - Follow-up task ^ssyacbg: SIGTERM in `run` mode and in the composition window of `acp` mode. The bootstrap facts (logging bootstrapped twice, OTEL_SDK_DISABLED) stay in the coordinator's task 01M3N940KBZ34KVDXHW4BQJ199.
  timestamp: 2026-09-29T01:24:41.860317+00:00
- actor: claude-code
  id: 01m3nc7b9tgx1tb99x9qarfszy
  text: |-
    ### implement — changed
    - evidence: 14 files. Sources: Sources/acp-agent/{TelemetryBootstrap,AcpAgentCommand,AcpCommand,InterruptHandler}.swift (modified), Sources/acp-agent/TerminationHandler.swift (new). Unit tests: Tests/FoundationModelsACPAgentTests/{TerminationHandlerTests,TelemetryShutdownTests}.swift (new). Integration: TelemetryFlushTests.swift, Support/{OTLPTestReceiver,SpawnedACPAgent,PipeCloseOnExec}.swift (new); Support/{SignalledExecutableRun,BuiltExecutableRun,ProcessCensus}.swift (modified). `swift test`: 597 tests in 68 suites passed (1 known issue, as before). `swift test --package-path IntegrationTests --filter TelemetryFlushTests`: 4 tests passed. `swift test --package-path IntegrationTests`: 24 tests in 10 suites passed, two runs in a row. No compiler warning from project sources. Package.resolved pins unchanged (Router bbad3ce, Extras 0dc42cf). Not committed.
    - next: /review. Follow-up ^ssyacbg (SIGTERM outside the ACP serve window).
  timestamp: 2026-09-29T01:24:47.546860+00:00
- actor: claude-code
  id: 01m3nd9ksedgetms94skrzxvzv
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d9764b5), 3 findings (3 confirmed, 0 refuted) — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/BuiltExecutableRun.swift:60, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SignalledExecutableRun.swift:142, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SpawnedACPAgent.swift:169
    - next: Extract the common process setup (Process, environment, pipes, close-on-exec marks) into one shared helper. Use it in BuiltExecutableRun, SignalledExecutableRun and SpawnedACPAgent. Then run the review again.
  timestamp: 2026-09-29T01:43:30.350870+00:00
- actor: claude-code
  id: 01m3nda6ggfsz2w8jrt59ta3j2
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 14 files (2-second flush bound in TelemetryBootstrap, flush in exitAfterFailure, TerminationHandler, tests, OTLPTestReceiver, SpawnedACPAgent, PipeCloseOnExec)
    - test: green — swift test 597 tests in 68 suites; IntegrationTests 24 tests in 10 suites; 0 project warnings
    - commit: d9764b5
    - review: findings — IntegrationTests/.../Support/BuiltExecutableRun.swift:60, SignalledExecutableRun.swift:142, SpawnedACPAgent.swift:169 (duplication)
  timestamp: 2026-09-29T01:43:49.520631+00:00
- actor: claude-code
  id: 01m3ndmfqgmp439vqb1sssasgr
  text: |-
    Review findings (duplication, 3 items) resolved.
    - New `IntegrationTests/.../Support/PipedChildProcess.swift`: one `init(executableNamed:arguments:workspace:inheritedEnvironment:environment:standardInput:)` makes the `Process`, sets the environment (the `environment` pairs on top of `inheritedEnvironment`), makes the stdout and stderr pipes, marks each pipe close-on-exec (also the stdin pipe when the caller gives one), and sets them on the process. `static func environment(configHome:adding:)` gives `XDG_CONFIG_HOME` with the extra pairs on top, so the configHome merge also stands in one place.
    - `BuiltExecutableRun` passes `ProcessInfo.processInfo.environment`, `SignalledExecutableRun` passes its `inheritedEnvironment`, and `SpawnedACPAgent` passes `environmentWithoutOpenTelemetry` and its own stdin pipe. The `FoundationModelsACPAgentTestSupport` import went out of the first two files, because they no longer use it.
    - What did not work: a first shape made the stdin pipe inside the helper (`pipesStandardInput: Bool`) and gave it back as `Pipe?`. The caller then had to unwrap it, and `#require` is not available outside a test. So the caller now makes the stdin pipe and gives it to the helper.
    - The environment merge order is the same as before: configHome first, then the extra pairs replace it.
  timestamp: 2026-09-29T01:49:26.640992+00:00
- actor: claude-code
  id: 01m3ndmjydcevgnv71zzteyhxp
  text: |-
    ### implement — changed
    - evidence: 4 files. New: IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/PipedChildProcess.swift. Modified: Support/BuiltExecutableRun.swift, Support/SignalledExecutableRun.swift, Support/SpawnedACPAgent.swift. `swift build --build-tests`: build complete, 0 warnings from project sources. `swift test --package-path IntegrationTests`: 24 tests in 10 suites passed (OutOfProcessTests, InterruptTests, TranscriptRecordingTests, ClientServerTests, ClientInteropTests, CLIProcessTests, TelemetryFlushTests, TelemetryStdoutTests, StdioContractTests, SkillTriggerTests), 0 warnings from project sources. Package.resolved pins unchanged. 3 of 3 findings checked. Not committed.
    - next: /review.
  timestamp: 2026-09-29T01:49:29.933997+00:00
- actor: claude-code
  id: 01m3ne2q9bkvpxwtaqpr5ftyys
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 9ab356f). 0 findings (0 confirmed, 0 refuted, 7 validator runs, 0 failed). 4 files reviewed. 2 files in `.kanban/` were not reviewed because `.reviewignore` excludes them. The 3 earlier duplication findings (BuiltExecutableRun.swift, SignalledExecutableRun.swift, SpawnedACPAgent.swift) are checked. The code fixes them: each of the three files now calls the shared `PipedChildProcess` helper in Support/PipedChildProcess.swift. Only that helper creates a `Process` and its pipes for these three runs.
    - next: none. The task is in done.
  timestamp: 2026-09-29T01:57:13.131687+00:00
- actor: claude-code
  id: 01m3ne344qpvkr92m5vq1c3mvh
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — PipedChildProcess.swift (new), BuiltExecutableRun.swift, SignalledExecutableRun.swift, SpawnedACPAgent.swift; 3/3 findings checked
    - test: green — swift test 597 tests in 68 suites; IntegrationTests 24 tests in 10 suites; 0 project warnings
    - commit: 9ab356f
    - review: clean — 0 findings; the task is in done
  timestamp: 2026-09-29T01:57:26.295516+00:00
depends_on:
- 01M3MNB6VZFQ81436GMVVJXE66
position_column: done
position_ordinal: ec80
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
- [x] Give `TelemetryBootstrap` one `static func shutdown() async` that flushes and shuts down the OTel service, with a fixed deadline (for example 2 seconds), so a dead collector cannot hold the process. When OTel is not bootstrapped (no `OTEL_EXPORTER_OTLP_ENDPOINT`), it does nothing.
- [x] Call `shutdown()` before the normal return of `main()` and before `Darwin.exit` in `exitAfterFailure(_:)`.
- [x] Add a `SIGTERM` watch (a `DispatchSourceSignal`, the same shape as `InterruptHandler.onSIGINT`). On `SIGTERM`: close the ACP connection, call `shutdown()`, then exit with the code for a signal end. Put it in `Sources/acp-agent/InterruptHandler.swift` or in a new `Sources/acp-agent/TerminationHandler.swift`.
- [x] Keep the second-`SIGINT` `_exit` as it is: the user asked to end at once, and a flush can wait on the network. Write this limit in the doc comment of `TelemetryBootstrap`.

## Acceptance Criteria
- [x] With `OTEL_EXPORTER_OTLP_ENDPOINT` set to a local test receiver and a long batch delay (`OTEL_BSP_SCHEDULE_DELAY=600000`, so only the shutdown flush can send), the last span of the run gets to the receiver on each of these paths: end of stdin in `acp` mode, the first `SIGINT` during a `run` turn (exit 4), and `SIGTERM` in `acp` mode after one prompt.
- [x] With the receiver stopped (nothing listens on the port), each of these paths ends in less than 5 seconds, with its usual exit code.
- [x] With no `OTEL_*` variable, the exit codes and stdout stay as before (the existing `CLIProcessTests`, `InterruptTests` and `TelemetryStdoutTests` pass).

## Tests
- [x] Add a small OTLP/HTTP receiver in `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/OTLPTestReceiver.swift` (an `NWListener` on `127.0.0.1` that records each request body). Use the OTLP protocol that swift-otel supports for HTTP; if it supports `http/json`, set `OTEL_EXPORTER_OTLP_PROTOCOL=http/json` so the test can read the span names.
- [x] Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryFlushTests.swift` with one case for each exit path above. Use `TierThreeFixture.stubModelEnvironment` and the paced stub of `InterruptTests.swift` for the `SIGINT` case. Assert that the receiver got at least one span whose name starts with `FoundationModelsRouter.` (a Router span, so this task does not wait for OTel 6). Do not assert one exact Router span name: the pinned Router bbad3ce names the prompt span `FoundationModelsRouter.turn`, and a newer Router (c682155 and later) names it `FoundationModelsRouter.submission`.
- [x] Add one case with no receiver on the port, and assert the exit time and the exit code.
- [x] Run `swift test --package-path IntegrationTests --filter TelemetryFlushTests`. Expected: pass.
- [x] Run `swift test` and `swift test --package-path IntegrationTests`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel

## Review Findings (2026-09-28 20:32)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 12 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/BuiltExecutableRun.swift:60` `duplication/duplication` — Lines 60-61 are part of a process setup block (lines 47-65) that is 0.97 identical to SignalledExecutableRun.run(). The blocks differ only in environment source (ProcessInfo.processInfo.environment vs an inherited parameter), making them one function with a parameter. Extract the common process setup code (Process creation through pipe assignment and marking) into a shared helper function that both BuiltExecutableRun.run() and SignalledExecutableRun.run() call, parameterizing the environment source.
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SignalledExecutableRun.swift:142` `duplication/duplication` — Lines 142-143 are part of a process setup block (lines 129-145) that is 0.97 identical to BuiltExecutableRun.run(). The blocks differ only in the environment parameter (inheritedEnvironment vs ProcessInfo.processInfo.environment), making them one function with a parameter. Extract the common process setup logic into a shared helper function parameterized by environment source, and call it from SignalledExecutableRun.run().
- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SpawnedACPAgent.swift:169` `duplication/duplication` — Line 169 is part of a process setup block (lines 156-173) that is 0.86-0.94 identical to the process setup in both BuiltExecutableRun.run() and SignalledExecutableRun.run(). All three files initialize Process, set environment, create pipes, and mark them close-on-exec in nearly identical patterns. Extract the common process setup pattern (Process initialization, environment setup, pipe creation, and close-on-exec marking) into a reusable helper function to be used across all three files, eliminating the maintenance burden of keeping these patterns in sync.
