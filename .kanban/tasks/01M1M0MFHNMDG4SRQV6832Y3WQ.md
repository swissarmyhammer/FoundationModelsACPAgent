---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1m7fbzj1ht9kqnvkqt7mhpx
  text: |-
    Research and measurement, before the code.

    **The file tree moved.** The card body line numbers are stale. The tier-2 proofs are in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` (a root unit target). The shared harness is a library target at `Tests/FoundationModelsACPAgentTestSupport/`. Tiers 3 and 4 are a nested package at `IntegrationTests/`.

    **What the seatbelt sandbox actually does, measured through the composed session.** The seatbelt sandbox does NOT refuse before the spawn, and it sends NO message of its own to the wire. The command runs. The kernel refuses the `open` of the redirect with `EPERM`. Three facts were read from one run of the new proof:

    1. The terminal stream carries exactly `/bin/sh: <path>: Operation not permitted` and nothing else. Stderr IS teed to `terminal_output_chunk`.
    2. The ACP terminal exit report carries `TerminalExitStatus(exitCode: nil, signal: nil)`. `TerminalStream.reportExit` sends an EMPTY exit status on purpose — its own doc comment says the presence marks the terminal exited and the stream carries no code. So the exit code is NOT readable there.
    3. The exit code IS readable from the run report the SECOND `wait` call answers: `{"commandID":...,"durationMs":10,"exitCode":1,"lines":1,"output":["1: /bin/sh: <path>: Operation not permitted"],"status":"completed"}`.

    **Why the second `wait` call.** In code mode through Router, `tools.shell.execute` declares a background mount, so its JS answer is the pending envelope, not the run report. The first `wait` settles the `runCode` run and answers that envelope. The nested shell run registers only when the snippet resolves, so a SECOND `wait` collects it, and the run report reaches the wire under that third scripted tool call.

    **The two doors are different.** Proof 2 refuses a READ through Multitool's `PathGuard`. plan.md §11.7 bounds the sandbox to writing and deleting, and the shell's gate is the sandbox alone. The new proof goes through the sandbox, so the two proofs do not measure the same door.
  timestamp: 2026-09-03T18:11:09.426149+00:00
- actor: claude-code
  id: 01m1m838fqjyq544nvwzxvfsdf
  text: |-
    Proof 8 landed: `TierTwoTests.aSandboxedShellWriteOutsideTheRootSetNeverLands`.

    **What it drives.** A `runCode` snippet calls `tools.shell.execute` with `printf '<content>' > '<path outside the root set>'`, on a session whose cwd is a fresh temp directory. Two `wait` plays follow, because the shell run mounts in the background.

    **What it asserts.**
    1. The disk holds no file at the target path (`FileManager.fileExists`). This is the claim.
    2. The terminal stream carries the shell's own message: it names the refused path and carries `Operation not permitted`.
    3. The run report the second `wait` answered carries `status: completed` and an `exitCode` that is not `0`. Both fields are read from decoded JSON, never from a rendered string.
    4. The turn still ends `endTurn`.

    **RED, watched.** `SandboxComposition.composeShell` was temporarily changed to hand the shell a pass-through `CommandSandbox` — `preflight` does nothing, and `wrap` returns the shell path and arguments unchanged, so no sandbox is composed. The proof then failed with FOUR issues: the file LANDED on disk, the stream carried no refusal, the stream did not name the path, and the exit code was `0`. The production file was reverted with `git checkout` and holds no probe code.

    **Refactor, to keep the file free of the duplication the new proof would have added.** Four readers now stand in the Readers section and serve both proof 7 and proof 8: `terminalExitStatus(of:)`, `waitForTerminalExit(of:)`, `terminalChunks(in:)` and `streamedTerminalText(in:)`. `streamWaitStepCount` became `shellWaitStepCount`, because two proofs now use it.

    **Cross-reference.** The suite doc comment gained a "Where the denial coverage lives" paragraph naming the two doors and pointing at `SandboxCompositionTests` and `MultiRootConfinementTests`. The proof's own doc comment repeats the pointer and names the mechanism.

    **Rules checked by measurement, not by eye.** `swiftlint` with the `no_magic_numbers` gate, the `disallowed-constructs-swift` roster and the `function_body_length`/`closure_body_length` gate each report nothing. `swiftformat --lint` with the `idioms-swift` roster reports the same three pre-existing findings on the working tree as on the HEAD copy of the file, and none in the new code. One finding was found and corrected during the work: `streamedTerminalText` first used a `var` accumulator loop, which the Swift immutability rule forbids; it now uses `map` and `joined()`.
  timestamp: 2026-09-03T18:22:01.207898+00:00
- actor: claude-code
  id: 01m1m83fm0b5e062vhpef18wa6
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift. `swift test` → 350 tests in 34 suites passed, 0 failed, 0 skipped, 1 known issue (the pre-existing `withKnownIssue` in `HarnessSmokeTests`); the baseline was 349, so the new proof is the one added test. `swift build --build-tests` and `swift build --build-tests --package-path IntegrationTests` both clean, zero warnings. RED watched: with a pass-through sandbox composed in place of the seatbelt sandbox, the proof failed with 4 issues, the disk assertion among them.
    - next: ready for /review
  timestamp: 2026-09-03T18:22:08.512928+00:00
- actor: claude-code
  id: 01m1m8byjfb2p82tct6zmtekgd
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 6a0a72c). 7 validators ran, 0 failed. 0 findings, 0 confirmed, 0 refuted. 1 file reviewed: Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift. 2 files not reviewed — the `.kanban/` ignore rule excludes them.
    - next: The task moves to `done`. No open finding is on the card.
  timestamp: 2026-09-03T18:26:45.967815+00:00
- actor: claude-code
  id: 01m1m8cnfpk8azhv4cvxj4h7w9
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file, Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift. Proof 8 `aSandboxedShellWriteOutsideTheRootSetNeverLands` added. RED watched first: with a pass-through sandbox in place of the seatbelt sandbox, the proof failed with 4 issues, the disk assertion among them.
    - test: green — root `swift test`, 350 tests in 34 suites passed, 0 failed, 0 skipped, 1 pre-existing known issue. `swift build --build-tests` and `swift build --build-tests --package-path IntegrationTests` both clean, zero warnings.
    - commit: 6a0a72c — 3 files, 280 insertions, 43 deletions. Local only.
    - review: clean — `review sha HEAD~1..HEAD`, 7 validators attempted, 0 failed, 0 findings.
    - next: The card is in `done`. No open finding stands.
  timestamp: 2026-09-03T18:27:09.430695+00:00
- actor: claude-code
  id: 01m1mg2gm5se8ase3yfadnqp4z
  text: |-
    Research, by measurement, of the CI failure in run 33801690872 (`TierTwoTests.swift:592`, the `#require` in `shellRunReport(of:)`).

    **Local repetition: the proof NEVER failed here.** 25 runs of `swift test --filter aSandboxedShellWriteOutsideTheRootSetNeverLands` with an idle machine: 25 pass, 0 fail. 20 more runs with 36 busy loops on an 18-core machine (2x the core count): 20 pass, 0 fail. 45 consecutive local passes, so the race cannot be shown by repetition on this machine.

    **What the `wait` verb does, read from the source.** `WaitTool.call` with no `completionToken` takes `context.backgroundRuns()`, which `SessionMailbox.backgroundRuns()` builds from `runsByToken`/`trackingOrder`. `markSettled` REMOVES a run from both the moment it settles. So the no-token `wait` reads a SNAPSHOT of the runs that have not settled yet:

    - a run not yet registered: absent from the snapshot;
    - a run registered and still going: in the snapshot, and the call blocks for it;
    - a run that already settled: absent, exactly like a run that never existed.

    With an empty snapshot the tool answers the OBJECT `{"result":"nothingPending","detail":"..."}` — not an array. That is the failure at that line: `runs as? [[String: Any]]` is `nil` for an object, so `.first?["detail"]` is `nil` and the `#require` fails. The reported message matches this shape exactly.

    A TOKEN-named `wait` is a different answer: `SessionMailbox.wait(completionToken:seconds:)` reads `settledTerminalEvents` FIRST and returns `.settled` for a run that already finished. The retention is the newest 128 settlements, and the turn holds two runs, so a token-named collection cannot miss.

    **The race, reproduced.** A probe turn that starts the shell run and then holds 300 ms in the snippet before returning made the collecting `wait` answer `{"result":"nothingPending",...}` — the exact CI symptom. The probe also measured the shapes: `tools.shell.execute` answers a JS STRING holding the pending envelope; the first `wait` play collects the `runCode` run; the second collects the shell run; and the shell run's own tool call in `ACPSessionState.toolCalls` carries the Terminal reference and NO `rawOutput`, so the exit code is reachable through a `wait` answer alone.

    **So the mechanism is confirmed, and the direction is named.** The shell run reports `durationMs` of 10 or 11. The snippet resolves about 1 ms into that life, which is what releases the first `wait`. The collecting `wait` must therefore reach the mailbox inside the remaining ~10 ms, or the run has settled and been reaped and the answer is `nothingPending` for ever. A loaded runner takes longer than that between two plays.
  timestamp: 2026-09-03T20:41:25.381632+00:00
- actor: claude-code
  id: 01m1mgq280xcsrpfn11s2yrptz
  text: |-
    The fix: the collecting play NAMES its run, and the snippet holds the shell run.

    **Two changes, and each removes one snapshot read.**

    1. `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift` gains `ScriptedTurnStep.collectingToolCall(name:)`. The step invokes the named tool with `{"completionToken": <the token the step before it answered>}`, read out of that answer, because a script is written before the session mints a token. A token-named `wait` reads `settledTerminalEvents` FIRST, so it collects a run that already settled as readily as one still going. `ScriptedModelError.noRunToCollect` makes a play with no token to name fail loudly instead of falling back to the snapshot read the step exists to avoid.

    2. Proof 8's snippet now holds the shell run itself, through the sandbox's own `wait(completionToken, seconds)` global, and returns that run's report as the `runCode` run's own value. The turn then plays ONE collecting `wait` that names the `runCode` run. Neither collection reads a snapshot.

    **The bound is not a guess.** The sandbox `wait` global demands a seconds number (`SandboxGlobalError.missingWaitDeadline` without one). The proof passes `ToolContext.deadlineSecondsCeiling`, which is the host's own no-bound value: `SessionMailbox.boundedNanoseconds` caps every seconds-valued deadline there, and `WaitTool.unboundedSeconds` passes the same value for a call that names none. So the wait ends when the run ends, never on a clock of its own, and the guard on a run that never ends stays the proof's `.timeLimit(.minutes(1))`.

    **Measured, that the race is gone.** A probe played TWO collecting waits. The second ran after the `runCode` run had settled and `markSettled` had removed it from `runsByToken` and `trackingOrder`, and it still answered the whole run report (`exitCode` 1). The same second play under the old no-token shape answered `{"result":"nothingPending"}`. That is the property the fix stands on, measured rather than argued.

    **Every claim of the proof stands, watched RED.** With `SandboxComposition.composeShell` handing the shell a pass-through `CommandSandbox` — `wrap` returns the shell path and arguments unchanged — the rewritten proof fails with the SAME four issues the first version failed with: the file LANDED on disk, the stream carried no `Operation not permitted`, the stream did not name the path, and the `exitCode` was `0`. The production file was reverted with `git checkout` and carries no probe code. The run report was still reachable in that RED run, so the collection is sound in both directions.

    **What did not work, so the next agent does not repeat it.** The exit code is NOT reachable outside a `wait` answer. Measured: the nested shell run's own tool call in `ACPSessionState.toolCalls` carries the Terminal reference and no `rawOutput`; the `runCode` run's own tool call carries neither; and the `runCode` scripted call keeps the pending envelope. The ACP exit report carries an empty `TerminalExitStatus`. So reading the report from the session state instead of a `wait` answer is not an option.

    Also rejected: a larger fixed `waitStepCount`. Extra plays cannot recover a settled run, because `markSettled` reaps it, so a later unnamed play answers `nothingPending` just as the earlier one did. It widens no window at all.

    `nestedRunWaitCallId` is removed, because proof 8 was its one caller and the turn now plays two scripted calls.
  timestamp: 2026-09-03T20:52:38.784568+00:00
- actor: claude-code
  id: 01m1mgqamradtray65tgzcks9g
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift (the `collectingToolCall` step) and Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift (the holding snippet, the one collecting play, the reader, the removed `nestedRunWaitCallId`). Root `swift test` → 351 tests in 34 suites passed, 0 failed, 0 skipped, 1 known issue (the pre-existing `withKnownIssue` in `HarnessSmokeTests`) — the baseline count, unchanged. `swift build --build-tests` and `swift build --build-tests --package-path IntegrationTests` both clean, zero warnings. The fixed proof ran 55 times in a row with no failure: 30 on an idle machine, and 25 more with 36 busy loops on 18 cores. Before the fix it ran 45 times with no failure too, so repetition is not what proves the fix — the probe is: a collecting play that names a run collected it after `markSettled` had reaped it, where the no-token play answered `nothingPending`.
    - next: ready for /review
  timestamp: 2026-09-03T20:52:47.384309+00:00
- actor: claude-code
  id: 01m1mkrk1ph2vqngg5fhky1pfy
  text: |
    ### review — clean
    - evidence: `review sha c27ffdb~1..c27ffdb` — 0 findings, 0 confirmed, 0 refuted. 7 validators ran, 0 failed. 2 source files reviewed: `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`, `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`. 2 board files under `.kanban/` were not reviewed, because an ignore rule excludes them.
    - next: The task moves to done. No prior review findings were open.
  timestamp: 2026-09-03T21:45:54.486293+00:00
- actor: claude-code
  id: 01m1mks7racpv70vwgztsw51pe
  text: |-
    ### finish iteration 2 — clean
    - cause: The CI runner failed the proof, and this machine passed it. A `wait` call that names no completion token reads only the background runs that are not settled. `SessionMailbox.markSettled` removes a run at the moment it settles, thus a settled run is absent in the same way as a run that is not yet registered. An empty snapshot answers an object and not an array, thus the decode of the run report failed.
    - implement: changed — 2 files, Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift and Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift. The snippet holds its own shell run, and the turn plays one collecting `wait` that names the run.
    - test: green — root `swift test`, 351 tests in 34 suites passed, 1 pre-existing known issue. Both packages `build --build-tests` with zero warnings. The fixed proof passed 55 times in sequence, 25 of them with a load of two times the cores.
    - commit: c27ffdb — 4 files. Pushed with the batch.
    - review: clean — `review sha c27ffdb~1..c27ffdb`, 7 validators ran, 0 failed, 0 findings.
    - CI: the unit job of run 33804894382 is green.
    - next: The card is in `done`. No open finding stands.
  timestamp: 2026-09-03T21:46:15.690778+00:00
position_column: done
position_ordinal: aa80
title: Add a tier-2 proof that the seatbelt sandbox denies a shell write outside the root
---
## What
No tier-2 proof shows the seatbelt sandbox refusing anything. Proof 7 (`aStreamedShellRunRidesTheTerminalStreamAndConverges`) runs a real sandboxed shell, but it only writes inside the root. Proof 2 refuses a read, and the mechanism there is Multitool's `PathGuard`, not the sandbox.

Plan.md §11.7 says the sandbox is the only gate for the shell. The seven proofs never exercise that gate.

## Why
Denial coverage exists in `SandboxCompositionTests.aWriteOutsideTheRootSetNeverLands` and `MultiRootConfinementTests.aPathOutsideTheRootUnionIsStillRefused`, and both are good. Neither drives the client end, and neither is part of the tier-2 set, so the tier-2 file gives a reader no way to find them.

## How
Add one proof to `TierTwoTests.swift`, in the shape of the others: a scripted `runCode` snippet that calls `tools.shell.execute` with a command that writes to a path outside the session root set, then the `wait` plays.

Assert from the client end:
- The write did not land — read the target path from disk and prove no file is there. The disk is the truth (plan.md §20.1); never take a `tool_call_update` claim for it.
- The refusal reaches the wire in band, and names the sandbox mechanism rather than `PathGuard`, so the proof and proof 2 do not measure the same door twice.
- The turn still ends `endTurn`, and the run settles.

Name the mechanism honestly in the doc comment. If the observable refusal text comes from the shell's own exit report rather than from a named sandbox message, say that: the claim is that the write did not land, and the exit is the evidence.

Cross-reference the two existing denial tests from the tier-2 file, so a reader finds the whole picture from one place.

## Acceptance Criteria
- [x] A tier-2 proof drives a real sandboxed `shell.execute` that writes outside the root set
- [x] The target path holds no file afterwards, read from disk
- [x] The refusal is visible to the client, and the doc comment names the mechanism that produced it
- [x] The tier-2 file cross-references `SandboxCompositionTests` and `MultiRootConfinementTests`
- [x] `swift test` → green

## Tests
- [x] The new proof, watched to fail first against a sandbox that is not composed (prove the test can fail)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.