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
position_column: doing
position_ordinal: '80'
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