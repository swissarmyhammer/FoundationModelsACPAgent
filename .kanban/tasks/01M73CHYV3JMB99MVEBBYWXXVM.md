---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78hp797nfmrk0zn26tvfret
  text: |-
    Research (implement step):
    - ScriptedPlaybook.makeSibling() gives each new backend (fork, replaced transcript, restore through ScriptedLLMContainer.makeSession(transcript:)) a fresh Progress. Thus a restored backend chooses its session by the continue prompt, which matches no entry, and echoes.
    - Router records an empty `.response` entry (segments: []) for a pass that did not answer (RoutedSessionActorAnswerExecution.recordFailedSubmission). Thus an orderly stop leaves prompt + reasoning + empty response for the pass at the gate, and a kill leaves prompt + reasoning only. A count of all `.response` entries would count the stopped pass as ended and skip the gate. The fix counts only a `.response` entry that has segments (the scripted backend always writes one text segment).
    - Router also calls replacingTranscript for discovery priming before each answer and for the repetition-watch rebuild. With the fix these continue the script, where before they started the script again.
    - Plan: the playbook sibling takes the seeded entries. When they hold a `.prompt` entry, the first prompt chooses the session, and the next pass is the count of ended passes. With no prompt entry (fresh, blank compaction transcript), the sibling chooses by its own first prompt as before.
  timestamp: 2026-11-12T18:52:57.511160+00:00
- actor: claude-code
  id: 01m78jn58ngt7kv23ma4ryvebj
  text: |-
    ### implement — changed
    - evidence: commit eef408e on branch par/bywxxvm (worktree par-bywx). Files: Sources/FoundationModelsACPAgent/Configuration/ScriptedPlaybook.swift, Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift, Tests/FoundationModelsACPAgentTests/ScriptedStubModelTests.swift.
    - fix: ScriptedPlaybook.makeSibling(continuing:) takes the seeded entries. The first `.prompt` entry chooses the session. The next pass is the count of `.response` entries that have segments. A pass with no response, or with the empty response that Router records for a pass that did not answer, plays again. Entries with no `.prompt` entry choose by the first prompt, as before.
    - test: aRestoredSessionPlaysThePassThatStoppedAtTheGateAgain(closedByRouter:) (two cases: the transcript of a kill, and of an orderly stop). RED before the fix (both cases: the pass echoed the continue prompt), GREEN after.
    - full run: `swift test --scratch-path <worktree>/.build`: 2015 tests in 220 suites passed, 1 known issue (HarnessSmokeTests, it was there before), 0 compiler warnings in Swift sources. IntegrationTests `swift build --build-tests`: exit 0, warnings only in the C/C++ code of checkouts (mlx-swift, libgit2).
    - open: work item 3 (tell FoundationModelsACPClient that its waits for a transient `running` must also fail on the idle state) and acceptance item 2 (10 runs of the two ACPClient tests) need the sibling repository. The dispatch said not to edit sibling repositories, so this step did not write a card there.
    - next: review.
  timestamp: 2026-11-12T19:09:51.253329+00:00
position_column: doing
position_ordinal: '8180'
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