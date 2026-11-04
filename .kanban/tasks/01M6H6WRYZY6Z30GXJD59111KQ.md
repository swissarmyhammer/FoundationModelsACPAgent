---
comments:
- actor: claude-code
  id: 01m6h7g59015y6g4kkzkbe185m
  text: 'CRASH REVIEW ITEM (independent, 2026-11-03): AgentRunner.cancelRuns(caller:) marks every child cancelled (run.cancel() marks cancelled and markEnded keeps the first write). If the quit path ever calls cancelRuns, every child ends cancelled and nothing is restored. The quit path of THIS task must use the Router suspendLiveSessions() first and runner.stop() (which marks nothing and posts no mail), and NEVER cancelRuns. Add a test that fails if the shutdown path calls cancelRuns. Also: the Agents package will add an environment closure to complete a claim on a live ROOT session (the host root session is a Router session, not an AgentRun); this package provides it with RouterSessionDirectory.session(id:) in the cold resume and re-drive tasks.'
  timestamp: 2026-11-03T17:32:21.152917+00:00
- actor: claude-code
  id: 01m6j7g7eagq8yzcy67e4y8jat
  text: |-
    ### implement — changed
    - note: commit 970ee65 for this work (id typed ^jd59111kq) sits only on branch wt-agents. It does not apply to main (conflicts with later commits), so it was not taken. The work was done fresh on main.
    - change: RoutedACPAgent.shutdown() (suspendLiveSessions first, then teardown with isShutdown); ComposedAgent.shutdown(); acp-agent AcpCommand and RunPrompt call shutdown(); SessionSurface.stopAgentRuns(cancellingCallers:) - a user close calls cancelRuns(caller: session) so each run is marked ended cancelled; a shutdown gives no callers and never calls cancelRuns. Connection-loss doc comment says nothing is suspended. README section "Shutdown and restart".
    - evidence: swift test --filter "SessionLifecycleTests|ConnectionCloseTests|AgentsToolTests|OrderlyShutdownTests|ResumeNestedSessionsTests": 38 tests passed. OrderlyShutdownTests: 4 tests pass (no ended marker, run .orphaned, no live session, user close marks cancelled).
    - files: Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift, Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/acp-agent/AcpCommand.swift, Sources/acp-agent/RunPrompt.swift, Tests/FoundationModelsACPAgentTests/OrderlyShutdownTests.swift, README.md
    - next: /review

    step: implement
    outcome: changed
    evidence: 7 files changed (listed above); all 7 checkboxes checked; 38 filtered tests pass
    task: ^59111kq
  timestamp: 2026-11-04T02:51:37.802982+00:00
position_column: doing
position_ordinal: '8380'
title: Orderly shutdown suspends the live sessions so working runs stay restorable
---
## What
At an orderly process shutdown the agent must leave working sessions and their runs restorable, like a clean crash. The Router now has a suspending close (Router main 29e7153a): `RoutedSession.suspend()` (nonisolated, idempotent) and `RouterSessionDirectory.suspendLiveSessions()`. After a suspend the journal refuses every `.completed` (the close sweep, a late tool body that swallows the cancel, and `completeClaimedRun` returns false); open claims stay open; runs stay `.orphaned` and claimable. A normal `close()` still cancels the work.

Today (read in the code, not run): `tearDownSession` (`Sources/FoundationModelsACPAgent/Agent/SessionLifecycle.swift`) stops the agent runs (`AgentsMount.runner`) and then closes the root session. At a process shutdown that cancels the working runs and the Router journals the cancellation, so the runs are not restorable. See the Router card "A tool run that the host cancels for a shutdown must not be journaled as succeeded" and the decision of the coordinator: no Extras change; suspend instead.

Do:
1. Find every path that ends the process or the connection of the agent (a signal, end of stdin, the connection close, the `acp-agent` command exit; see `Sources/acp-agent/InterruptHandler.swift` and the lifecycle code). For an orderly PROCESS shutdown call `RouterSessionDirectory.suspendLiveSessions()` first, then stop the runner and close the sessions. After the suspend, `runner.stop()` must mark nothing ended and post no result mail (the Agents package does this already; see its README).
2. A USER `session/close` or `session/cancel` is not a shutdown: it keeps the current behavior (cancel the work; the Agents package marks the run ended with reason cancelled).
3. A connection loss while the agent process lives is not a shutdown of the sessions: do not suspend them (the sessions stay active; ACP lets the agent continue or cancel foreground work; keep the current behavior and say so in a comment).
4. Write down the shutdown order in `README.md`.

## Acceptance Criteria
- [x] An orderly shutdown with a working nested run leaves the run `.orphaned` in the journal after a reload (use the real Router and a stub model), and the ended marker is not set.
- [x] A user `session/close` still cancels the work and marks the run ended.
- [x] A shutdown with no live session does nothing special and does not hang.
- [x] The shutdown order is in the README.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/OrderlyShutdownTests.swift`.
- [x] Run `swift test --filter OrderlyShutdownTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents