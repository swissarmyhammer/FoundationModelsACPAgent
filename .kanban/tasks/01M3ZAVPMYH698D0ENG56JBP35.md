---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3zax8bf4bsthatphgrjknc9
  text: 'Upstream confirmed and carded (FoundationModelsACP, 2026-10-02). `Connection.shutDown()` already runs on end of input, transport error and explicit close, but `AgentSideConnection` does not expose it. Proposed: `public var closed: ConnectionCloseReason { get async }` with `.endOfInput`, `.transportFailed(any Error)`, `.closedLocally`, on both AgentSideConnection and ClientSideConnection; it fires exactly once for all three paths, every waiter (also a late one) gets the same reason, and only after every inbound handler task has ended. The final name can change. Not started; the owner decides when it runs. Blocked until that session sends the commit.'
  timestamp: 2026-10-02T22:14:12.591093+00:00
- actor: claude-code
  id: 01m3zbdxb4egjty4xy5z75qc87
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — blocked on the upstream FoundationModelsACP "connection closed" signal (proposed `closed: ConnectionCloseReason`); carded there, not started, the owner decides when it runs
    - next: when that session sends the commit and the final name, move the pin and run /implement on this card
  timestamp: 2026-10-02T22:23:18.372204+00:00
- actor: claude-code
  id: 01m40stts7gcbc56xvprbch79s
  text: |-
    Unblocked: FoundationModelsACP ^afr96kt is on main at 284e002.
    ```swift
    public enum ConnectionCloseReason: Sendable {
        case endOfInput                  // the input stream of the transport finished
        case transportFailed(any Error)  // the input stream of the transport failed
        case closedLocally               // close() was called
    }
    // AgentSideConnection, ClientSideConnection (also Connection)
    public var closed: ConnectionCloseReason { get async }
    ```
    - Fires exactly once for all three paths; a late waiter gets the reason at once.
    - Fires only AFTER every inbound request task has ended (also deferred work and notification handlers). A request that arrives after close starts no handler.
    - Limits: do NOT await `closed` inside an inbound handler (it would never return) — start a separate task: `Task { let reason = await connection.closed; ... }`. Cancelling the waiting task does not stop the wait. A failed write does not close the connection.
    Use: when the agent binds a connection, start one task that awaits `closed`, then runs the session/close path for each open session (finish the shell stream, shut down the MCP pool, write session-history.json, release the session) and logs the reason. The task must hold the agent weakly, so it does not keep a dropped agent alive.
  timestamp: 2026-10-03T11:54:16.231122+00:00
- actor: claude-code
  id: 01m40tb3a9hmqey1fx1bmsabn3
  text: |-
    Research (2026-10-03). Correction of the last comment: the waiting task must hold the agent STRONGLY, not weakly.
    - Upstream at 284e002: `Connection.readTask = Task { await self.readLoop() }` holds the `Connection` strongly, and the `Connection` holds the request handler, which holds the `RoleHolder`, which holds the agent strongly. Thus the agent lives exactly as long as the read loop. `readLoop()` fires `closed` as its last step. So a task that holds the agent until `closed` returns adds no lifetime past the read loop: no leak.
    - A weak hold is wrong: after `closed` fires, the read loop ends, the `Connection` goes, and the agent can go before the weak task reads it. Then no session closes, and the Multitool `SurfaceRefresher` assertion stops the debug build. That is the defect of this card.
    - Experiment (a scratch test, removed): (1) client `close()` + `wire.close()` gives `closed == .endOfInput` at once. (2) A harness that the test drops with NO close: `closed` never fires in 3 s, and the agent is NOT released, also with no waiter task. The two read loops keep the two transport ends alive, so no input ends. That case already keeps the agent today, through the read loop; the waiter task does not change it. Each AgentReleaseTests case calls `harness.close()`, which gives `.closedLocally`.
    - Production: `acp` mode returns from `TerminationHandler.serve` at stdin EOF and the process exits; `run` mode closes the connection with no `session/close`. So the CLI must wait for the agent's teardown, or the process exits before the history is written.
  timestamp: 2026-10-03T12:03:09.257153+00:00
- actor: claude-code
  id: 01m40yezpr0gwh0n6179687ttd
  text: |-
    Implementation landed (not committed).
    Design (decided, reason in the research comment above): `RoutedACPAgent.bind(connection:)` starts one teardown task that holds the agent STRONGLY, waits for `connection.closed`, then calls `closeOpenSessions(after:)`: one `notice` record with `connection.close_reason` (`endOfInput` / `transportFailed` / `closedLocally`, plus `error.type` for a failed transport, never the error text), then the private `tearDownSession` (the `session/close` path) for each open session. The task handle is kept in a `Mutex`; `public nonisolated func waitForConnectionTeardown()` waits for it. The table entries stay, marked closed, as after `session/close`; the sessions go with the agent.
    - CLI: `run` (`RunPrompt.answer`) and `acp` (the `closing` closure of `TerminationHandler.serve`) now wait for `composed.waitForConnectionTeardown()` before the process exits, so the history is written and the MCP servers stop. `AgentComposition.Composed.waitForConnectionTeardown()` keeps the rule that only the composition names the agent type.
    - Test harness: `AgentClientHarness.close()` now waits for the teardown. Without that wait, the teardowns of the many tests that close the harness with open sessions ran in the background beside later tests, and `ProfileDoctorTests`/`ToolsDoctorTests` (a 0.2 s probe timer against a 2 s ceiling) failed twice in the full run (2.3 s to 3.6 s). Bisection with temporary env switches (removed): each teardown step alone passed; the full teardown in the background failed; the same teardown awaited inside `harness.close()` passed (baseline at HEAD also passes, 721 tests).
    - `ScriptedPromptFixture.close()` still sends `session/close` for each session. It is no longer necessary; it stays because it is harmless and uses the client request path. Its doc comment now says so.
    - `InboundEndTransport` doc corrected: the connection now tells the agent about the end (`closed`), but only after each handler ended, so the process still needs the raw stdin end.
    - Item 4 (the Multitool `SurfaceRefresher` assertion): the evidence does not support a change. After this card, a refresher is released without `stop()` only if a host drops a connection with no close at all, and then nothing is released (the read loops keep everything), so the assertion still marks a real host defect. No request to the Multitool session.
    - TDD note: the drop-the-wire test was RED first (the process stopped on `SurfaceRefresher.swift:136`), and the `run` test was RED (the session was open when `answer` returned). The log-record and reason-name tests were written after the log code.
  timestamp: 2026-10-03T13:15:10.936087+00:00
- actor: claude-code
  id: 01m40yf65e14mykhgg5y7bdv6v
  text: |-
    ### implement — changed
    - evidence: 12 files — Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/Telemetry/ACPAgentTelemetry.swift, Sources/acp-agent/AgentComposition.swift, Sources/acp-agent/AcpCommand.swift, Sources/acp-agent/RunPrompt.swift, Sources/acp-agent/InboundEndTransport.swift, Tests/FoundationModelsACPAgentTests/ConnectionCloseTests.swift (new, 3 tests), Tests/FoundationModelsACPAgentTests/RunCommandTests.swift (+1 test), Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift (doc), Tests/FoundationModelsACPAgentTestSupport/Harness.swift, plan.md §10.1; gitignored IntegrationTests/Package.resolved FoundationModelsACP pin moved e14d853 -> 284e002. `swift build -c release`: complete, 0 warnings. `swift test`: 725 tests in 82 suites passed (1 known issue, as at HEAD). `swift build --package-path IntegrationTests --build-tests`: complete (only the third-party mlx Metal header warnings of the checkout). Design: a teardown task started at bind holds the agent strongly until `closed` returns; no leak, because the read loop already holds the agent until `closed` fires.
    - next: /review
  timestamp: 2026-10-03T13:15:17.550448+00:00
- actor: claude-code
  id: 01m40yv7hrgchsvfscxptbgrft
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (d9b644a); 0 findings, 0 confirmed, 0 refuted; 7 validator runs, 0 failed. 11 files reviewed. Not reviewed: 4 .kanban files (.reviewignore) and plan.md (no validator matches).
    - next: none. The task moved to done.
  timestamp: 2026-10-03T13:21:52.184720+00:00
- actor: claude-code
  id: 01m40yvfq60tkae2v76mjhspnn
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 12 files (teardown task on `closed`, run/acp wait, harness wait, ConnectionCloseTests)
    - test: green — swift test 725 tests in 82 suites; release build 0 warnings; IntegrationTests build (reported by implement)
    - commit: d9b644a
    - review: clean — 0 findings
  timestamp: 2026-10-03T13:22:00.550341+00:00
position_column: done
position_ordinal: ff9380
title: A connection that drops without session/close leaves its sessions open, and a debug build stops on a Multitool assertion
---
## Problem

Found in ^hkr6ykz / ^w93shct (2026-10-02). The session history sink holds the agent and the connection weakly. When a client drops the connection with no `session/close`, the agent and its sessions go away without a close. A session that mounts an MCP server then releases its `SurfaceRefresher` while its watch task still runs, and Multitool's debug assertion stops the process (`SurfaceRefresher.swift:136`). The tests avoid it because `ScriptedPromptFixture.close()` now sends `session/close` for each session. A host in production can still drop the connection.

## Cause

FoundationModelsACP gives the agent no signal that its connection closed (end of stdin, transport error). Thus the agent cannot run its own close path for each open session.

## What to do

1. Ask the FoundationModelsACP session for a public "connection closed" signal on `AgentSideConnection` (for example an async `closed` property or an `onClose` callback that runs one time).
2. When it is pushed: on that signal, the agent runs its `session/close` path for each open session (finish the shell stream, shut down the MCP pool, write `session-history.json`), then releases the sessions.
3. Test: a scripted client that drops the wire with an MCP-mounted session open; the process does not stop, the history file is written, and the model pool is empty.
4. Separately, consider whether the Multitool assertion at `SurfaceRefresher.swift:136` must be a log line, not an assertion, because a release without a stop is possible. Ask the Multitool session if the evidence supports it. #upstream