---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21hz1fqcr1cxb00jr4c71pj
  text: |-
    ### The upstream card is made

    `FoundationModelsACPClient` card **`^man82w6`** — "N6: --timeout, the interrupt, and the reaping proofs". It is in `todo` and carries the full specification of this card.

    This card stays open until that one is done and merged to ACPClient `main`.
  timestamp: 2026-09-08T22:24:36.343759+00:00
- actor: claude-code
  id: 01m21wtfe3314kzdrb5yrgzanp
  text: |
    ### The upstream work is verified on ACPClient `main`

    This is a tracking card, so this pass is verification and closure. No
    code changed in this repository.

    **The upstream state.** `../FoundationModelsACPClient` is on branch
    `main`, its working tree is clean, and `main` and `origin/main` are both
    `a11baae`. The commit `3051c5c` ("feat(interrupt): prove the timeout,
    interrupt, and reap exit paths") is on `main` and is pushed. The
    upstream card `^man82w6` is in `done`, with a recorded `review — clean`
    step (`review sha HEAD~1..HEAD`, 10 files, 0 findings).

    **Each acceptance criterion, and where it stands.** Every claim below
    comes from reading the upstream source and tests, not from the ledger.

    1. *A turn past `--timeout` exits 124.*
       `--timeout` is an option in `Sources/AcpClientCore/SharedOptions.swift`
       and 124 is `ExitCode.timeout` in `Sources/AcpClientCore/ExitCode.swift`.
       `TimeoutTests.anAgentThatNeverGoesIdleExitsWithTheTimeoutCode` drives
       the real binary against a stub that streams one chunk and then sends
       no `state_update`, and asserts `SectionNineExitCode.timeout`.
       `TimeoutTests.theAnswerThatArrivedBeforeTheLimitIsStillWritten`
       asserts the partial bytes.

    2. *A `SIGINT` during a turn exits 4, with the partial text on stdout,
       and `session/cancel` reached the agent before the exit.*
       `InterruptTests.oneInterruptCancelsTheTurnAndExitsWithTheCancelledCode`
       asserts `SectionNineExitCode.cancelled` AND
       `transcriptHolds(transcript, method: "session/cancel")`, which reads
       the agent's own record of the requests that reached it.
       `InterruptTests.theAnswerThatArrivedBeforeTheInterruptIsStillWritten`
       asserts byte equality of stdout with the answer. The press waits
       until the transcript holds `session/prompt`, so the signal lands
       inside a live turn.

    3. *A second `SIGINT` ends the run inside a named time bound.*
       `InterruptTests.twoInterruptsEndARunWhoseAgentIgnoresTheCancellation`
       drives an agent that IGNORES `session/cancel`, sends two presses, and
       asserts the elapsed time is under `secondInterruptRunBudget`, a named
       constant of 2 seconds, beside the exit code 4.

    4. *After each of success, failure, timeout and interrupt, no process in
       the agent's process group is alive.* A reaping test exists per exit
       path, and each one uses `expectAgentGroupIsGone(ledBy:after:)` in
       `Support/StubAgents.swift`, which asserts BOTH `!processExists(pid)`
       and `!processGroupHasLiveMember(ledBy: pid)`. The group probe in
       `Support/TransportTestSupport.swift` is `kill(-leader, 0) == 0`, so it
       really reads the group and not only the leader.
       - success: `RunCommandExitTests.noAgentProcessOutlivesTheRun`, over
         `TurnEnding.allCases` — `endTurn`, `refusal`, `cancelled` and the
         idle that reports no stop reason;
       - failure: `NoLeakedAgentTests.noAgentProcessOutlivesTheRun`, over
         `NoLeakScenario.allCases`, which holds the exit-1 rows
         `runReachesAnAgentThatGoesAwayMidTurn` and
         `runReachesAnAgentThatRefusesTheSession`, plus
         `aFailedSpawnLeavesNothingBehind`;
       - timeout: `TimeoutTests.noAgentProcessOutlivesATimeout`;
       - interrupt: `InterruptTests.noAgentProcessOutlivesACancelledRun`,
         and the two-press row reads the pid as well.

    5. *The `DispatchSourceSignal` handler body only sets a flag.* In
       `Sources/AcpClientCore/InterruptHandler.swift` the `setEventHandler`
       body is one statement:
       `self.pendingInterrupts.add(created.data, ordering: .sequentiallyConsistent)`.
       The work runs on a normal drain task that `start()` begins and
       `stop()` cancels, and it reads the flag every 20 ms.
       `InterruptHandlerSourceTests.theEventHandlerSetsTheFlagAndCallsNothingElse`
       reads the file, takes the closure body by counting braces, drops
       blank and comment lines, and asserts one statement with one call.

    **One note on the last test row.** "`swift test` in
    `../FoundationModelsACPClient` passes" is ticked from the upstream
    ledger of `^man82w6` — 229 tests in 21 suites, 0 warnings, and 92
    integration tests in 13 suites, 0 warnings — and not from a run of my
    own, because this card may not build in that repository. The CI run for
    the head commit was still queued when I read it.

    Nothing is missing. Every subtask, acceptance row and test row is
    ticked.
  timestamp: 2026-09-09T01:34:21.123931+00:00
- actor: claude-code
  id: 01m21wtx2rcjj1g0wr27tamh4c
  text: |
    ### implement — changed
    - evidence: card content only, 2 files — /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/.kanban/tasks/01M1MR8849R5508HXGEBTRRZAV.md and its .jsonl. No source file of this repository changed, so the root `swift test` baseline of 497 tests in 52 suites is untouched. The tracked upstream work is on `FoundationModelsACPClient` `main` at commit `3051c5c`, and each acceptance row was read in the upstream source and tests before the box was ticked.
    - next: ready for `/review`.
  timestamp: 2026-09-09T01:34:35.096581+00:00
depends_on:
- 01M1MP6PBZ3X4FAA6CVCFKR6VW
position_column: doing
position_ordinal: '80'
title: 'acp-client N6: --timeout, the interrupt, and the reaping proofs'
---
### What

Upstream work in `../FoundationModelsACPClient`, milestone **N6** of its
`cli-plan.md` §11.

- `--timeout <seconds>`: end the run if the turn does not stop in time,
  and exit 124, the `timeout(1)` convention.
- `Ctrl-C`: send `session/cancel`, wait for the `cancelled` stop reason,
  print the text that arrived, reap the agent, exit 4. A second `Ctrl-C`
  ends the run at once, and it still reaps the agent.
- Use a `DispatchSourceSignal`, and do the work on a normal task. The
  handler body only sets a flag, because a signal handler must be
  async-signal-safe.

**The obligation this card exists for: no agent process outlives the
run.** This holds after success, after a failure, after a timeout, and
after an interrupt. `AgentProcess` already spawns the agent in its own
process group; this card proves the reaping.

A leaked agent holds gigabytes of model weights, so each exit path gets
its own test.

- [x] `--timeout`, and exit 124
- [x] The first and the second `Ctrl-C`
- [x] Reap the agent in every exit path

### Acceptance Criteria

- [x] A turn that runs past `--timeout` exits 124.
- [x] A `SIGINT` during a turn exits 4, and the partial text is on
      stdout.
- [x] A second `SIGINT` ends the run inside a short, named time limit.
- [x] After each of success, failure, timeout and interrupt, no process
      in the agent's process group is alive.
- [x] The `DispatchSourceSignal` handler body only sets a flag.

### Tests

- [x] A timeout test against a stub that never finishes: exit 124.
- [x] An interrupt test: exit 4, and the recording client shows a
      `session/cancel` reached the agent before the exit.
- [x] A second-interrupt test with a time bound.
- [x] One reaping test per exit path: after the run, the agent's process
      group holds no live process.
- [x] A source-level test that the signal handler body sets a flag and
      calls nothing else.
- [x] `swift test` in `../FoundationModelsACPClient` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
