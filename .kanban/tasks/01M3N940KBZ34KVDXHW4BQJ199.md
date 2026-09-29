---
comments:
- actor: claude-code
  id: 01m3ng1r8ey57kexczznd4qhb5
  text: |-
    Research (swift-otel 1.5.1 in .build/checkouts):
    - `OTel.makeLoggingBackend(configuration:)` returns `(factory, service)`. It does not bootstrap. It reads `ProcessInfo.processInfo.environment`; no overload takes an environment dictionary. The only caller of `TelemetryBootstrap.bootstrap(environment:)` passes the process environment, so the two agree.
    - `OTel.bootstrap(configuration:environment:)` bootstraps logs, then metrics, then traces, each only when enabled. A throw after the logs step leaves `LoggingSystem` bootstrapped and loses the logs service.
    - `OTEL_SDK_DISABLED` sets `logs.disabled`, `metrics.disabled` and `traces.disabled` in both directions. So `OTEL_SDK_DISABLED=false` (or empty) turns logs ON again in a configuration that has `logs.enabled = false`, and `OTel.bootstrap` then calls `LoggingSystem.bootstrap` a second time. The traces and metrics bootstrap must get the environment without that key (the agent already checked it).
    - An unknown `OTEL_TRACES_EXPORTER` value does NOT fail: swift-otel writes a warning and keeps `otlp`. The known values `zipkin`, `jaeger` and `console` for traces throw `NotImplementedError` in `WrappedSpanExporter.init`. The failing traces case uses `zipkin`.
    - The Bool parse of swift-otel is case-insensitive (`true`, `false`, empty).
    - Item 3: no doc comment in the sources says that the default swift-log handler writes to stdout. The only text with that claim was the description of ^vvjxe66. The new doc comments state the stderr default and the real reasons for the bootstrap.
    - Neither the agent nor the pinned Router writes swift-log records yet, so a test cannot see a log record reach the receiver.
  timestamp: 2026-09-29T02:31:38.510063+00:00
- actor: claude-code
  id: 01m3ngw1pps5dwyygb4nf5rkrn
  text: |-
    Implementation landed:
    - `Sources/acp-agent/TelemetryBootstrap.swift`: `bootstrap(environment:)` now (1) checks `exportsTelemetry(environment:)` (endpoint set and not empty, and `OTEL_SDK_DISABLED` not `true` in any case); (2) makes the logging backend with `OTel.makeLoggingBackend` through `installLogging(from:otherwise:installing:)`, which installs exactly one factory (the backend, or the stderr fallback when the backend throws); (3) calls `OTel.bootstrap` with `logs.enabled = false` and the environment from `tracingAndMetricsEnvironment(from:)` (no `OTEL_SDK_DISABLED`); a throw writes the reason to stderr and leaves the logging as it is; (4) runs the services that started in one `ServiceGroup`. `shutdown()` and the 2-second bound did not change.
    - Doc comments: the enum doc states the one-bootstrap rule, the SDK switch, and that the swift-log default handler writes to stderr; the executable still states its own handler.
    - New unit suite `Tests/FoundationModelsACPAgentTests/TelemetryBootstrapTests.swift` (no bootstrap in process): the export choice (with `TRUE`/`True`/`true`, and `false`/`FALSE`/empty/`yes`), the traces and metrics environment, and the install step with a recorder (one install on success and on failure).
    - New support `IntegrationTests/.../Support/SpawnedAgentPromptDrive.swift`: the drive of one prompt over `SpawnedACPAgent`. `TelemetryStdoutTests` and `TelemetryFlushTests` both use it, so the drive has one copy. `TelemetryStdoutTests` no longer needs the `/usr/bin/env -u` start: `SpawnedACPAgent` takes an environment, closes stdin and gives the exit code, so each case now also checks a clean exit 0.
    - New integration cases: `aFailedTracesConfigurationKeepsTheAgentRunning` (`OTEL_TRACES_EXPORTER=zipkin`, because an unknown value does not fail in swift-otel 1.5.1), `anSDKSwitchOfFalseKeepsTheAgentRunning`, and `theSDKSwitchStopsEachExport` with `TRUE` and `true` against `OTLPTestReceiver` (no request).
    - RED: the unit suite failed to compile before the change (the members did not exist). The integration cases pass on the old code too (swift-otel itself obeys `OTEL_SDK_DISABLED`, and the old catch did not bootstrap a second time); they are regression guards. `anSDKSwitchOfFalseKeepsTheAgentRunning` guards against the split without the key removal.
    - Manual check: `acp-agent acp` with `OTEL_TRACES_EXPORTER=zipkin` writes "The OpenTelemetry traces and metrics bootstrap failed..." to stderr and exits 0.
    - The build shows SwiftPM "failed loading cached manifest ... disk I/O error" warnings (the manifest cache, with the data volume at 99 %) and the known mlx `missing creator for mutated node` warning. Neither comes from the sources of this project.
    - Package.resolved (root and IntegrationTests) did not change: Router bbad3ce, Extras 0dc42cf.
  timestamp: 2026-09-29T02:46:00.150443+00:00
- actor: claude-code
  id: 01m3ngw4cb8phvc1g6gvy0egfq
  text: |-
    ### implement — changed
    - evidence: 5 files: Sources/acp-agent/TelemetryBootstrap.swift, Tests/FoundationModelsACPAgentTests/TelemetryBootstrapTests.swift (new), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SpawnedAgentPromptDrive.swift (new), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryFlushTests.swift. `swift test`: 610 tests in 69 suites passed (1 known issue that was there before). `swift test --package-path IntegrationTests --filter "TelemetryStdoutTests|TelemetryFlushTests"`: 10 tests in 2 suites passed. `swift test --package-path IntegrationTests`: 28 tests in 10 suites passed. 0 warnings from project sources.
    - next: review
  timestamp: 2026-09-29T02:46:02.891947+00:00
- actor: claude-code
  id: 01m3nhhdaepv9ad1txa9w9cfjm
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 0eb73d1). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 5 files reviewed. 4 .kanban files not reviewed (.reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-09-29T02:57:40.174288+00:00
- actor: claude-code
  id: 01m3nhhnkvah6amjf59ya41qzw
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — TelemetryBootstrap.swift, TelemetryBootstrapTests.swift (new), SpawnedAgentPromptDrive.swift (new), TelemetryStdoutTests.swift, TelemetryFlushTests.swift
    - test: green — swift test 610 tests in 69 suites; IntegrationTests 28 tests in 10 suites; 0 project warnings
    - commit: 0eb73d1
    - review: clean — 0 findings; the task is in done
  timestamp: 2026-09-29T02:57:48.667657+00:00
depends_on:
- 01M3MNNAQ6YMAM4T4E9RM6R3RH
position_column: done
position_ordinal: ee80
title: 'OTel 2c: bootstrap logging one time, and obey OTEL_SDK_DISABLED, in acp-agent'
---
## What
The FoundationModelsACPClient session found three facts about swift-otel 1.5.1 that affect `Sources/acp-agent/TelemetryBootstrap.swift` (OTel 2 ^vvjxe66, commit 988a354). This task follows OTel 2b ^rm6r3rh, which changes the same file.

1. `OTel.bootstrap` can bootstrap logs and then fail on metrics or traces. A second `LoggingSystem.bootstrap` stops the process. Now `bootstrap(environment:)` calls `OTel.bootstrap` for traces, logs and metrics together, so a failure can leave logging half set up. ACPClient uses `OTel.makeLoggingBackend` and one `LoggingSystem.bootstrap`, and calls `OTel.bootstrap` for traces and metrics only.
2. `OTEL_SDK_DISABLED` must be checked, without case sensitivity, before the bootstrap. When it is `true`, use the stderr handler and no-op tracing and metrics, the same as when `OTEL_EXPORTER_OTLP_ENDPOINT` is not set.
3. Correction of a reason: the default swift-log handler writes to stderr (`StreamLogHandler.standardError`, swift-log `LoggingSystem.swift`), not to stdout. The bootstrap and the stdout test stay necessary. Correct each doc comment that gives stdout as the reason.

Work:
- [x] In `Sources/acp-agent/TelemetryBootstrap.swift`: make the logging backend with `OTel.makeLoggingBackend` (or the swift-otel 1.5.1 API with that job), call `LoggingSystem.bootstrap` exactly one time on every path, and call `OTel.bootstrap` for traces and metrics only (logs off in its configuration).
- [x] If the logging backend cannot be made, bootstrap the stderr handler one time. If the traces and metrics bootstrap fails, logging stays as it is, and the reason goes to stderr.
- [x] Check `OTEL_SDK_DISABLED` without case sensitivity before any bootstrap.
- [x] Correct the doc comments about the default handler (item 3).

## Acceptance Criteria
- [x] No path of `bootstrap(environment:)` calls `LoggingSystem.bootstrap` two times.
- [x] With `OTEL_EXPORTER_OTLP_ENDPOINT` set and a traces or metrics configuration that fails (for example an unknown `OTEL_TRACES_EXPORTER` value), `acp-agent acp` does not crash, answers `initialize`, and stdout has only ACP frames.
- [x] With `OTEL_SDK_DISABLED=TRUE` (and `true`) and an endpoint set, the agent sends nothing to the endpoint.
- [x] No doc comment says that the default swift-log handler writes to stdout.

## Tests
- [x] Add cases to `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TelemetryStdoutTests.swift`: a failing traces configuration (no crash, good `initialize`, stdout only ACP frames), and `OTEL_SDK_DISABLED=TRUE` with the local OTLP test receiver of OTel 2b (the receiver gets no request).
- [x] Run `swift test --package-path IntegrationTests --filter "TelemetryStdoutTests|TelemetryFlushTests"`. Expected: pass.
- [x] Run `swift test`. Expected: all tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#otel