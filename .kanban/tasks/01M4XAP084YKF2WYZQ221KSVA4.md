---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xj698m9xg5fwz56pxtybra
  text: |-
    T6 decisions (step lead, 2026-10-14):
    - Plan items 1-10 accepted: remove each .timeLimit; WatchedValue moves to FoundationModelsACPAgentTestSupport and backs UpdateCollector and the test doubles; Poll.until, maxPollAttempts and pollInterval go; SessionModel waits use withObservationTracking; journal reads wait for awaitIdle() (checked: Pump.swift:273 endPumpWork comes after the awaited journal appends, Recording.swift:486, Sinks.swift:121); a forever body waits for cancellation; run timeouts use ManualRunClock; skills reload waits for SkillsRegistry.onReload; MCP server exit uses a kqueue process source; LateReadProgress uses a semaphore; IntegrationTests use terminationHandler, a watched store, awaitIdle(), and no hang guards.
    - Q1: add internal awaitPromptsFinished(of:), resumed when openPrompts becomes empty, no clock. Drop the waits that only came before a follow-up prompt.
    - Q2: DeallocationWatch with an associated object, for a deinit.
    - Q3: an internal closure for the first index pass in BuiltRegistry.
    - Q4: do not only remove the sleep. A test sink holds each chunk at a gate. If needed, add a small internal observation point in TerminalStream (a counter with change events) and assert on it in a fixed order, so a read-ahead reader fails each time.
    - Q5: use ModelPool.footprints (public in Extras) for an event wait like Router's awaitNoResidentModel(); no 60 s poll.
  timestamp: 2026-10-14T15:58:41.428520+00:00
- actor: claude-code
  id: 01m4xm7kzbrzeyvx41bpxc8ssp
  text: |-
    T6 part 1: commit 8c7308e. Root suite: one full run, 937 tests pass, 1 known issue (not new), no warnings (23 s, before 29 s). IntegrationTests builds with no warnings; it is not run here (the one full run of IntegrationTests is in T7).

    Later decisions (step lead): Q2 changed to C (a command provider that only the agent holds) and B1 (the scripted backends of the Router sessions, with BackendLifetimes; each test also expects no compaction), because an actor refuses associated objects. Q6: A (Extras adds an event wait to TelemetryCapture.Context). Q7: B (the skill trigger gate has no decision deadline; it measures what the model chose, not when).

    Differences: the release tests use the scripted model; AgentsToolTests slow-run test has a settle period of 0 on a ManualRunClock that never moves; LateReadProgress uses a semaphore; NamedPipe uses a blocking open on a thread; SinkRecorderTests startWait uses a kept-wait event; IntegrationTests pins now match the root pins.

    Open: part 2, the six telemetry capture waits (AgentSpanTests:127, TelemetryContentSafetyTests:200, RequestTracingTests:138 and :344, SessionSurfaceLoggingTests:70, AgentMetricsTests:112), and the delete of Support/Poll.swift. They wait for the Extras commit.
  timestamp: 2026-10-14T16:34:22.315856+00:00
depends_on:
- 01M4XANTXS2E7ECKH044PJHZ63
position_column: doing
position_ordinal: '80'
title: 'T6: Remove the .timeLimit traits and each sleep, clock wait and poll in the tests'
---
Step 4 of the mail work, part T6. Do this task after T5.

Work:
- Remove the 298 .timeLimit traits in Tests.
- Remove each sleep, clock wait and poll in Tests, IntegrationTests and EvaluationTests.
- Replace each one with a wait on an event, a gate or a fixed order.
- Do not delete a test without a decision from the step lead.

The rules of T0 (STE, commit and report after each task, one full test run, no .timeLimit/sleep/poll/retry, ask before a decision that is not in the plan) apply. #mail-step-4 #tests