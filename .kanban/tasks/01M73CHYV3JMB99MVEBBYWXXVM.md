---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: 'Cold resume of a scripted stub run: the restored run does not play its script again, so the ACPClient nested-run tests can hang'
---
## What
Found during ^4273b5t (2026-11-10). Two ACPClient integration tests sometimes hang until their 120 s limit: `anOrderlyQuitResumesTheRunsAndCompletesTheOriginalAgentsCall` and `aKilledAgentResumesTheNestedRunWithItsTree` (FoundationModelsACPClient `IntegrationTests/.../AgentNestedScenarioTests.swift`, `AgentNestedRunTests.swift`). Both do a COLD resume in a new agent process, not a hot resume. So the fix of ^4273b5t does not touch them.

Probable cause (read of the code, about 70 percent sure, not reproduced):
1. After the restart, `redriveInterruptedRuns` (`Sources/FoundationModelsACPAgent/Agent/SessionResumeRedrive.swift`) starts each restored run. FoundationModelsAgents `AgentRunner.restoreChild` gives the run the prompt `AgentsToolText.restoredRunContinue` ("The process stopped while you worked...").
2. The scripted stub backend of the restored session is new, with no progress. `ScriptedPlaybook.steps(forPrompt:)` (`Sources/FoundationModelsACPAgent/Configuration/ScriptedPlaybook.swift`) selects the passes only from the current prompt (`script.passes(forFirstPrompt:)`). The continue prompt holds no marker, so the steps are `[.textDelta(prompt)]`.
3. Thus the restored grandchild does not play its `gate` step again. It echoes the prompt and goes idle at once. The `running` state lasts only a few milliseconds.
4. The client test waits for `grandchild.workState == .running` with `orFailWhen: { session.isClosed }` only. When the client does not see the short `running` state, the wait never ends.
- The warnings "A session/update send failed" (ConnectionError) come from sends to the closed connection of the first process at shutdown. `Connection.notify` throws at once on a closed connection, so they do not block. They are not the cause.

## Work
1. Reproduce in this package with a deterministic test: record a scripted stub session that stops at a gate step, restore it, re-drive it with the continue prompt, and expect that the pass waits at the gate (it echoes the prompt now).
2. Fix the stub: when the backend has seeded entries, select the passes from the first prompt of the seeded transcript, and continue from the recorded pass count. Or decide with the user that a restored run plays a dedicated script entry.
3. Tell FoundationModelsACPClient: its waits for a transient `running` should also fail on the idle state of the grandchild (their test code, not this package).

## Acceptance Criteria
- [ ] A restored scripted run continues its script after a cold resume, or the decision is recorded.
- [ ] The two ACPClient tests do not hang in 10 runs (foundationmodelsacpclient confirms).

## Tests
- [ ] A deterministic unit test of the restored scripted pass (fails before, passes after).
- [ ] `swift test` passes with no warnings.