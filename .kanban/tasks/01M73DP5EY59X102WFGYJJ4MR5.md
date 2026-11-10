---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73dpqy71ytg25xyehw4rx1n
  text: 'Decision of testudoapp-75 (2026-11-10): step1. Use fix (a): FoundationModelsAgents records the task prompt before the announcement, with a deterministic test there. The cause was sent to foundationmodelsagents-d7. New scope of this card: after the Agents commit, bump only the Agents pin and add an end-to-end restore test in this package (a run killed after its announcement comes back on `session/resume` with its prompt). Use fallback (b) only if Agents says the order cannot change; then tell testudoapp-75 why.'
  timestamp: 2026-11-10T19:07:08.103807+00:00
- actor: claude-code
  id: 01m73dt87r8rh9wc71kns4azq6
  text: 'foundationmodelsagents-d7 accepted the defect as Agents task ^vejnx2n (step1, bug). A run records its task prompt durably before it is announced, for a host-started run and for a nested run. The restore reads that record, and a host `prompts:` value still wins. Its test holds the first generate, waits for the announcement, stops, restores and expects the run back with its prompt, with no wall-clock waits. Agents order: ^1yb868r (in review), then ^vejnx2n, then ^mpqd9de.'
  timestamp: 2026-11-10T19:09:03.096621+00:00
- actor: claude-code
  id: 01m73g164psfhvdgk6zzmw5m0t
  text: |-
    Agents ^vejnx2n is pushed (FoundationModelsAgents main, head e181a24; fix 28808c9, review fixes 6027446 and b4e3824; swift test 934 passed; review clean). This card is no longer blocked.
    What changed: `AgentRun.make` writes the task prompt to `task-prompt.md` in the session folder right after it makes the session, before the run is in the runner index (so before any announcement). The restore takes the prompt from the host `prompts:` first, then this record, then the Router first prompt. A record that cannot be read logs a warning and the restore uses the next source.
    Host requirement: the record is under the recording root, so `AgentEnvironment` must have `recordingRoot` set. ACPAgent sets it through `agentRunHost`; confirm it in the test.
    Next run: bump only the Agents pin (with Skills if needed, as in ^b013mv9), and add the end-to-end restore test: a nested run killed after its announcement and before its first generate comes back on `session/resume` with its prompt, and no `restoreFailure`.
  timestamp: 2026-11-10T19:47:47.478490+00:00
- actor: claude-code
  id: 01m73hnfatc14s8bkcgcs528nn
  text: When this card is pushed, send its commit hash to testudoapp-75 AND to foundationmodelsacpclient-76. foundationmodelsacpclient-76 runs its integration package 10 times on it (the `aKilledAgentResumes…` test).
  timestamp: 2026-11-10T20:16:20.826014+00:00
- actor: claude-code
  id: 01m73mspv42tbw3k62aytgvgsy
  text: |-
    Research (implement step):
    - Package.resolved pins FoundationModelsAgents at 609c812. `git merge-base --is-ancestor e181a24 609c812` is true, so the pin includes the fix of ^vejnx2n. No pin change.
    - ACPAgent sets the recording root: `AgentRunHost.linking(_:)` calls `environment.withRecordingRoot(recordingRoot)`. The public `restoreInterrupted(of:caller:directory:)` makes `RestoreSource(directory:recordingRoot: environment.recordingRoot)`, so the restore reads `task-prompt.md`.
    - The window on disk: the Router writes its `promptStarted` marker only when the pump takes the mail. No seam holds the pump before the take (the Agents test says the same and hides the Router prompt in its source). `RestoreSource` is internal to Agents, so this package cannot hide it in the source. The end-to-end test thus holds the grandchild in its first pass (a named-pipe signal from a `writeFile` step, then `holdUntilReleased`, so no model output), kills the process (history written, sessions suspended, no close), and removes the `promptStarted` and `prompt` events from the transcript of the grandchild. That is the state on disk of a kill before the take.
    - Observable "with its task prompt": the grandchild agent body holds `$ARGUMENTS`, so the instructions of the restored Router session hold the task prompt.
  timestamp: 2026-11-10T21:11:05.316022+00:00
- actor: claude-code
  id: 01m73n6kawb43t2wq90wvejefr
  text: |-
    ### implement — changed
    - What: a new end-to-end suite `TaskPromptRecordRestoreTests` (5 tests). The first agent records root -> child -> grandchild. The grandchild writes one byte to a named pipe (`writeFile` step) and then holds (`holdUntilReleased`), so it plays no model output. The test waits on the pipe (no clock), kills the process (history written, sessions suspended, no close), and removes the `promptStarted`/`prompt` events from the transcript of the grandchild. That is the state on disk of a kill before the pump takes the mail. A second agent sends `session/resume`.
    - Results: `task-prompt.md` is on disk after the announcement (this confirms that ACPAgent gives `recordingRoot` through `AgentRunHost`). The grandchild comes back nested in the child. Its instructions hold the task prompt (the body is `$ARGUMENTS`). `nestedRestore.failed` is empty, so no `restoreFailure` is sent. Control test: with `task-prompt.md` removed, the restore fails the grandchild with `FailedChild.promptNotRecordedReason`.
    - RED: a temporary removal of `task-prompt.md` in the fixture made the 3 restore tests fail (the grandchild was not restored, `failed` was not empty). GREEN after the removal was taken out.
    - The Agents fix covers the ACPAgent path, so the `prompts:` fallback is not used. No pin change: Package.resolved is at 609c812, which includes e181a24.
    - Test support: `AgentFolderFixture` and `AgentsToolTests.writeAgent` take an optional `body:` (the default is unchanged). `ResumeNestedSessionsTests` has `LeafPlay` and `recordInterruptedChain(leafPlay:beforeKill:)`. `recordInterruptedChain()` keeps its old behavior. `NamedPipeSignal` was added in Support/NamedPipe.swift.
    - evidence: Tests/FoundationModelsACPAgentTests/TaskPromptRecordRestoreTests.swift (new), Tests/FoundationModelsACPAgentTests/ResumeNestedSessionsTests.swift, Tests/FoundationModelsACPAgentTests/Support/NamedPipe.swift, Tests/FoundationModelsACPAgentTests/AgentsToolTests.swift, Tests/FoundationModelsACPAgentTestSupport/AgentFolderFixture.swift. `swift test --filter TaskPromptRecordRestoreTests`: 5 passed. Full `swift test`: 1959 tests in 215 suites passed, 0 failures (1 known issue from the `withKnownIssue` that was there before in HarnessSmokeTests), 0 compiler warnings.
    - next: /review. After the push, send the commit hash to testudoapp-75 and foundationmodelsacpclient-76. The IntegrationTests package was not run. The change to the fixture only adds a default parameter, so the source stays compatible.
  timestamp: 2026-11-10T21:18:07.708393+00:00
position_column: doing
position_ordinal: '80'
title: A run killed after its announcement but before its task prompt was recorded is never restored
---
## What
Found from a frame dump of FoundationModelsACPClient `aKilledAgentResumesTheNestedRunWithItsTree` (2026-11-10, ACPAgent 728276c; trace at /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsACPClient/c6a2f1c1-d86c-4e3e-8e84-1327458d50a2/scratchpad/flaky-trace.txt). This replaces the guess of ^bywxxvm for this test.

Sequence: the grandchild run is announced `running` and sends a running `state_update`, and the child lists it as background work. Then the process is killed. On `session/resume` in the new process, the child gets a `subagent_update` for the grandchild with `_meta.sah.restoreFailure.reason = "its task prompt was not recorded"` (`FailedChild.promptNotRecordedReason`, FoundationModelsAgents `AgentRunRestore+Interrupted.swift`). The grandchild never runs again, and its `agents` call completes with the "process stopped" text and an empty result.

Cause: a persist-order window. A run is announced and runs before its task prompt is recorded. A kill in that window loses the run. ACPAgent calls `AgentRunner.restoreInterrupted(of:caller:directory:)` (`SessionResumeNested.swift`) with no `prompts:`, so it gives no fallback.

1. Reproduce it in this package with a deterministic test: start a nested run, stop the process state after the announcement and before the prompt record (a gate in the test), and restore.
2. Fix one of two ways (prefer (a)):
   (a) FoundationModelsAgents records the task prompt of a run before the run is announced or starts. That is a change in the sibling repository: send the exact cause to foundationmodelsagents-d7 and wait for its commit.
   (b) As a fallback in this package: give `prompts:` to `restoreInterrupted` from the recorded `agents` call of the caller (the prompt argument of the open `start agent` call in the caller history), keyed by the child session id.
3. Tell foundationmodelsacpclient-76 the result. The test must not accept a `restoreFailure` for this case after the fix.

## Acceptance Criteria
- [ ] A run killed at any point after its announcement is restored on `session/resume`, with its task prompt.
- [ ] No `restoreFailure` with `promptNotRecordedReason` for a run whose `agents` call is in the caller history.

## Tests
- [ ] A deterministic restore test for the window above, which fails before the fix.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1