---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m738ec2rsmdvm09h2qb8htrq
  text: 'Changes (2026-11-10): testudoapp-75 put this card in step1 (a hang of the session composition in OpenTestudo is a real defect). foundationmodelsmultitool-2a asks: (1) send it the exact cause if the wait is in `StdioServerProcess` or `MCPServer.connect` (Multitool); it then makes a Multitool card with a regression test; (2) a test for it must NOT depend on time. Thus replace the "under 5 seconds" criterion: the test waits for the composition to end (for example with a gated process or an exit signal), not for a clock. The criterion is: `session/new` ends, and the server shows as failed. For the server that never answers, a time limit constant is still the product rule, but the test gives a short injected limit or a fake clock.'
  timestamp: 2026-11-10T17:35:10.936034+00:00
- actor: claude-code
  id: 01m73gk9216g9weaq8hqwfnjpj
  text: |-
    Research (2026-11-10): the wait is in FoundationModelsMultitool (pinned revision 4f0c664c2d29943a14d4666e96dfd167f6e8ce31), not in MCPComposition.

    Reproduced with diagnostic tests, which I did not keep (there is no commit). A config stdio entry `/bin/sh -c "read line; exit 0"`, `"read line; exit 1"` and `"exit 0"` all made `MCPComposition.connectServers` wait for more than 15 s. A bare Multitool `MCPServer.connect(via: process.respawn)` on the same script, after 10 s: `isTransportDropped == true`, `state == .connecting`. Thus Multitool knows about the drop, but the connect does not end.

    Exact cause:
    1. `Sources/FoundationModelsMultitool/Capabilities/MCP/MCPServer+Connection.swift`, `applyConnect(via:generation:)`: it awaits `made.client.connect(transport:)`. The swift-sdk `MCP.Client.connect(transport:)` sends `initialize` and waits for the pending request. The swift-sdk client resumes a pending request only in `disconnect()` and in a cancel. When the stream ends, its message loop stops and does not resume the pending request.
    2. `Sources/FoundationModelsMultitool/Capabilities/MCP/MCPServer+Call.swift`, `handleTransportDrop(generation:)`: `DropObservingTransport` reports the end of the stream here. The generation is current during the handshake, so the drop is recorded. But it fails only `inFlightCalls` (`failInFlightCalls`). It does not end the connect attempt that waits in the handshake (it does not tear down the attempt client, it does not move the state to `.faulted`). Thus the `initialize` wait never ends.
    3. The single-attempt `MCPServer.connect(via: TransportFactory)`, which `MCPComposition.connectToReady` uses, has no time limit. Only `connect(via:backoffPolicy:)` races `BackoffPolicy.connectTimeout` (default 10 s) through `performConnectAttempt(factory:timeout:)`.

    Point 3 has an agent-side part: the agent can use `connect(via:backoffPolicy:)` with a named policy for criterion 4. But the exit case (criteria 1 and 2) needs the Multitool change first. The Multitool fix proposal: a drop during the handshake of the current attempt ends that attempt (tear down the attempt client, so the pending `initialize` resumes with an error, and move to `.faulted`).

    Also a contract question for the orchestrator: the card says that a failed config server must give a failure record so that `session/new` still succeeds. But the documented contract of `MCPComposition.connectServers` is that a connect failure of a config-derived entry throws (test `aConfigServerThatFailsAfterAConnectedConfigServerStillThrows`). A person must decide if this card changes that contract for config entries.

    Environment note: a plain `swift build` in this worktree compiled the files of another worktree (agent-acfb1dc7cdccf262d). `swift build --scratch-path <worktree>/.build` builds the correct tree.
  timestamp: 2026-11-10T19:57:40.289763+00:00
- actor: claude-code
  id: 01m73gkc4ct2emyj82chmbeayy
  text: |-
    ### implement — stuck
    - evidence: no source change. Cause in FoundationModelsMultitool: `MCPServer+Call.swift` `handleTransportDrop(generation:)` fails only `inFlightCalls` and does not end the connect attempt that waits for `initialize` in `MCPServer+Connection.swift` `applyConnect(via:generation:)` (`made.client.connect(transport:)`); the single-attempt `connect(via:)` has no time limit. Diagnostic: bare `MCPServer.connect(via:)` on `/bin/sh -c "read line; exit 0"` after 10 s gives `isTransportDropped=true state=connecting`.
    - next: send the cause to foundationmodelsmultitool-2a; make this task depend on its commit; a person decides if a failed config server must still throw.
  timestamp: 2026-11-10T19:57:43.436448+00:00
- actor: claude-code
  id: 01m73gmmgnx74t855n4fzx0age
  text: 'Orchestrator (2026-11-10): the cause was sent to foundationmodelsmultitool-2a. This card waits for the Multitool fix. A decision was asked of testudoapp-75: a config server that fails to connect gives a failure record (session/new succeeds) or throws (today, `aConfigServerThatFailsAfterAConnectedConfigServerStillThrows`). Criterion 4 (time limit) is ours: use `connect(via:backoffPolicy:)` with a named policy. Build note for the next run: in a worktree under .claude/worktrees, use `swift build --scratch-path <worktree>/.build`.'
  timestamp: 2026-11-10T19:58:24.789900+00:00
- actor: claude-code
  id: 01m73gn855vag223vdd7m6fnzp
  text: 'Decision of testudoapp-75 (2026-11-10): the card rule. A config MCP server that fails to connect is recorded as failed: send it as failed in `_mcp_server_status`, with the reason. `session/new` succeeds with the other servers. Change the test `aConfigServerThatFailsAfterAConnectedConfigServerStillThrows` to the new rule, and add a test that the failed status reaches the client. This part does not need the Multitool fix, so it can be done first; the "process exits during the handshake" tests wait for the Multitool commit. A search of README.md, ARCHITECTURE.md and the ACPAgent spec found no text of the old rule; check the doc comments of `MCPComposition.connectServers` and change them.'
  timestamp: 2026-11-10T19:58:44.901029+00:00
- actor: claude-code
  id: 01m73hf98qh78w9vv60rexndfm
  text: |-
    The Multitool fix is pushed (FoundationModelsMultitool main, fix 43ae953c, tests 381dda64, head 558b503e). This card is no longer blocked. When the transport drops while the state is `.connecting`, MCPServer tears down the client of that attempt: `connect(via:)` throws `MCPError.connectionClosed`, and the state moves to `.faulted`. This covers a drop before the `initialize` answer and a drop during `tools/list`. After a drop, `DropObservingTransport.send(_:)` throws. A drop after `.ready` does not change the state. No public API change. Multitool test: MCPHandshakeDropTests (no clock).
    Next run of this card (in the main tree): bump only the Multitool pin to 558b503e or later; switch `MCPComposition.connectToReady` to `connect(via:backoffPolicy:)` with a named policy (criterion 4); apply the decision of testudoapp-75 (a failed config server is recorded as failed in `_mcp_server_status` with the reason, and session/new succeeds); change `aConfigServerThatFailsAfterAConnectedConfigServerStillThrows`; add the end-to-end tests with no clock.
  timestamp: 2026-11-10T20:12:58.007522+00:00
- actor: claude-code
  id: 01m73njdp5h3nxwckf84kat0ky
  text: |-
    Research (main tree, 2026-11-10):
    - Pins: `swift package update FoundationModelsMultitool` moved only Multitool, 4f0c664c -> 558b503e, in the root and in IntegrationTests. Both Package.resolved files are gitignored, thus the pin change is not in the git diff.
    - `connect(via:backoffPolicy:)` wraps the errors of the attempts: a failed or timed-out attempt gives `MCPServerError.backoffExhausted`, and a `NonRetryableConnectError` from the factory gives `MCPServerError.connectConfigurationFailed` (a string, not the error). Both map to `FailureReason.connectFailed`. `commandNotAbsolute` comes from the `StdioServerProcess` init, before the connect, thus its reason does not change. The `notAvailable -> stdioInSandboxedMode` row of the reason table is not reached through `connectServers`: the roster refuses each stdio entry in `sandboxed` mode before the connect.
    - The per-attempt timeout of Multitool sleeps on a real `ContinuousClock` (the public init gives no seam). The backoff delay between attempts sleeps on the injected `clock`. Thus the composition policy uses one attempt: a crashed server fails at once with no backoff sleep, and `session/new` waits at most the time limit for each server that never answers. The agent calls no `reconnect()` in Sources, thus the one-attempt policy does not change a reconnect path.
    - Tests that use the old throw rule of a config entry: `aRelativeStdioCommandThrowsInsteadOfSpawning`, `anHTTPServerURLThatDoesNotParseThrows`, `aConfigServerThatFailsAfterAConnectedConfigServerStillThrows` (MCPCompositionTests) and `configServerThatCannotStartCountsOneStdioConnectFailure` (AgentMetricsTests). They change to the new rule.
  timestamp: 2026-11-10T21:24:35.141852+00:00
- actor: claude-code
  id: 01m73p8gpqsnr9jsdkxkdk3jtz
  text: |-
    Implementation (2026-11-10):
    - `MCPComposition.connectServers` does not throw now (`async`, not `async throws`). A connect failure of a config entry gives a `.failed` outcome with the reason, the same as a client entry. The other servers stay connected, and `_mcp_server_status` shows the failed server. The doc comments of `connectServers`, `connect(entry:...)`, `Roster.Entry.origin`, `shutDown` and three `Throws` notes in ToolCatalog.swift are changed to match. The `try` of each caller is removed (ToolCatalog and the tests).
    - `connectToReady` uses `connect(via:backoffPolicy:)`. New constants: `connectTimeLimitSeconds = 10` and `connectBackoffPolicy` (one attempt, that time limit). `connectServers` has a new `backoffPolicy:` parameter (default `connectBackoffPolicy`) so that a test can give a zero time limit.
    - Tests: the exit tests ("exit 0", "read line; exit 1") end when the transport drops, not on a clock. The never-answers test uses `while read line; do :; done` and a zero time limit. Do NOT use `exec cat > /dev/null`: it closes stdout, so the transport drops and the test proves the wrong thing.
    - RED that I saw: before the change, the never-answers test went past its `.timeLimit(.minutes(1))` and did not stop, because the connect ignores cancellation. Thus the time limit trait cannot end a hung connect. Only the policy time limit ends it.
    - Pin side effect: Multitool 0d1e85ff (MT-15, in the bump range) removed the default of `MultiTool.Builder(mode:)`. I changed one test call site in SessionAgentToolsTests.swift to `MultiTool.Builder(mode: .open)`. That is the form that the other tests use. No other package moved.
    - Open note: with the backoff connect, a `notAvailable` error from `respawn` comes back wrapped as `MCPServerError.connectConfigurationFailed`. Thus the `notAvailable -> stdioInSandboxedMode` row of the reason table does not match it. `connectServers` cannot get to that path, because the roster refuses stdio entries in sandboxed mode first.
  timestamp: 2026-11-10T21:36:39.127996+00:00
- actor: claude-code
  id: 01m73p8mhpamfhg1qdvwy26akm
  text: |-
    ### implement — changed
    - evidence: 6 source/test files: Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift, Tests/FoundationModelsACPAgentTests/MCPServerStatusReportTests.swift, Tests/FoundationModelsACPAgentTests/AgentMetricsTests.swift, Tests/FoundationModelsACPAgentTests/SessionAgentToolsTests.swift. Pin: FoundationModelsMultitool 4f0c664c -> 558b503e in Package.resolved and IntegrationTests/Package.resolved (both gitignored), no other package moved. `swift build --build-tests`: no warnings. `swift test`: 1962 tests in 215 suites passed, 0 failures, 1 known issue (HarnessSmokeTests withKnownIssue, which this change did not touch). `swift build --build-tests --package-path IntegrationTests`: build complete, no warnings.
    - next: /review
  timestamp: 2026-11-10T21:36:43.062715+00:00
position_column: doing
position_ordinal: '80'
title: A config stdio MCP server that exits before it answers must not make session/new wait
---
## What
Found on 2026-11-10 during ^xfeamnv. A test marker script ran `touch` and then exited. In `open` mode the session composition waited for that config stdio server to answer the MCP `initialize`, and it did not stop when the process exited. The test run hung for more than 15 minutes. Thus a real config stdio server that crashes at start can make `session/new` wait for a long time.

1. Reproduce it in a test: a config `mcp:` stdio entry whose command exits at once with code 0, and one that exits with code 1.
2. Find where the wait is: `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift` (`connectServers`) and the Multitool `StdioServerProcess` / MCP client connect. If the cause is in FoundationModelsMultitool, do not edit that repository: report the exact cause to session foundationmodelsmultitool-2a and make this task depend on its commit.
3. The connect must end when the process exits before the handshake: record one failure for that server (the same record as other MCP connect failures, so `session/new` still succeeds and the server shows as failed), and go on with the other servers.
4. Confirm that a connect time limit exists for a server that stays alive and never answers. If there is none, add one with a named constant.

## Acceptance Criteria
- [ ] `session/new` with a stdio server that exits at once returns within a short time (for example under 5 seconds in the test), and the server shows as failed.
- [ ] The other MCP servers of the session still connect.
- [ ] A server that never answers fails at the time limit.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/MCPCompositionTests.swift`: the three cases above, with a time limit on each test.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1