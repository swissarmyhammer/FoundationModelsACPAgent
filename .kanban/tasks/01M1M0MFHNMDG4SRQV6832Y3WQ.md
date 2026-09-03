---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Add a tier-2 proof that the seatbelt sandbox denies a shell write outside the root
---
## What
No tier-2 proof shows the seatbelt sandbox refusing anything. Proof 7 (`aStreamedShellRunRidesTheTerminalStreamAndConverges`, `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift:576`) runs a real sandboxed shell, but it only writes inside the root. Proof 2 refuses a read, and the mechanism there is Multitool's `PathGuard`, not the sandbox.

Plan.md §11.7 says the sandbox is the only gate for the shell. The seven proofs never exercise that gate.

## Why
Denial coverage exists in `SandboxCompositionTests.aWriteOutsideTheRootSetNeverLands` (line 100) and `MultiRootConfinementTests.aPathOutsideTheRootUnionIsStillRefused` (line 195), and both are good. Neither drives the client end, and neither is part of the tier-2 set, so the tier-2 file gives a reader no way to find them.

## How
Add one proof to `TierTwoTests.swift`, in the shape of the others: a scripted `runCode` snippet that calls `tools.shell.execute` with a command that writes to a path outside the session root set, then the `wait` plays.

Assert from the client end:
- The write did not land — read the target path from disk and prove no file is there. The disk is the truth (plan.md §20.1); never take a `tool_call_update` claim for it.
- The refusal reaches the wire in band, and names the sandbox mechanism rather than `PathGuard`, so the proof and proof 2 do not measure the same door twice.
- The turn still ends `endTurn`, and the run settles.

Name the mechanism honestly in the doc comment. If the observable refusal text comes from the shell's own exit report rather than from a named sandbox message, say that: the claim is that the write did not land, and the exit is the evidence.

Cross-reference the two existing denial tests from the tier-2 file, so a reader finds the whole picture from one place.

## Acceptance Criteria
- [ ] A tier-2 proof drives a real sandboxed `shell.execute` that writes outside the root set
- [ ] The target path holds no file afterwards, read from disk
- [ ] The refusal is visible to the client, and the doc comment names the mechanism that produced it
- [ ] The tier-2 file cross-references `SandboxCompositionTests` and `MultiRootConfinementTests`
- [ ] `swift test` → green

## Tests
- [ ] The new proof, watched to fail first against a sandbox that is not composed (prove the test can fail)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.