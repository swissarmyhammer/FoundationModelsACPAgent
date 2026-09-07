---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1yzm8m6tk1p5bepek0pggtm
  text: |-
    ### Research

    What is in the tree now:

    - `AcpAgentCommand.usageExitCode: Int32 = 2` and `InterruptHandler.cancelledExitCode: Int32 = 4` are the two exit-code literals in `Sources/acp-agent/`. Both go into the new enum.
    - `AcpAgentCommand.exitOutcome(for:)` is the one exit path of the process. It maps the ArgumentParser `validationFailure` to 2 and keeps the library code for every other error. The new enum feeds it; no second mapping is written.
    - `AcpAgentCommand.Run.exitCode(of:)` holds the only stop-reason row today: `cancelled` gives 4, and every other reason gives `nil`. The new enum replaces it.
    - The wire `StopReason` (FoundationModelsACP `Unions2.generated.swift`) has six cases: `endTurn`, `maxTokens`, `maxTurnRequests`, `refusal`, `cancelled` and `unknown(String)`. The switch must cover all six.
    - `RunTurnResult.stopReason` is optional. `nil` means the wire ended before an idle update arrived. That is a protocol failure, so it gives 1, not 0. The old code gave 0.

    Measured facts from the ArgumentParser source (`MessageInfo.init(error:type:)`):

    - A `ValidationError` gives `ExitCode.validationFailure`, so the usage row is driven by a real error.
    - A thrown `ExitCode` gives an empty message, so nothing is written to either stream.
    - Any other error gives `ExitCode.failure`, which is 1, and a message on stderr.

    Names: the enum is `AgentExitCode` in `Sources/acp-agent/ExitCode.swift`. `ExitCode` alone would shadow the ArgumentParser type that the same files and the test files use, which makes every reference ambiguous.
  timestamp: 2026-09-07T22:25:39.974338+00:00
- actor: claude-code
  id: 01m1z036xj657k7kars5sza8q5
  text: |-
    ### implement — changed

    - evidence: 8 files. New: `Sources/acp-agent/ExitCode.swift`, `Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift`, `Tests/FoundationModelsACPAgentTests/Support/ScriptedInterruptWatch.swift`. Changed: `Sources/acp-agent/AcpAgentCommand.swift`, `Sources/acp-agent/RunCommand.swift`, `Sources/acp-agent/AcpCommand.swift`, `Sources/acp-agent/InterruptHandler.swift`, `Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift`, `Tests/FoundationModelsACPAgentTests/InterruptTests.swift`, `Tests/FoundationModelsACPAgentTests/CompositionInterruptTests.swift`. `swift build` completes with no warning. `swift test` gives 484 tests in 50 suites, all passed, with the one known issue at `HarnessSmokeTests.swift` the baseline carries. The baseline was 474 tests in 49 suites.
    - next: `/review`

    What the change did, step by step.

    The TDD order held: `ExitCodeTests` was written first and the build failed with "cannot find 'AgentExitCode' in scope" on 14 lines. The enum then made the suite green.

    `AgentExitCode` states the six rows. `init(stopReason:)` holds the ONE total switch, written as a switch expression with six arms and no `default`. `init(turn:)` reads a `RunTurnResult` and gives `error` for a `nil` stop reason. `parserError` makes the ArgumentParser `ExitCode` a subcommand throws.

    The two exit-code literals are gone. `AcpAgentCommand.usageExitCode` and `InterruptHandler.cancelledExitCode` are deleted, and `ExitOutcome` gained an `init(_ code: AgentExitCode)` so `exitOutcome(for:)` and every suite name a row instead of a number. `Run.exitCode(of:)` is deleted as well: `AgentExitCode(turn:)` is now the one name for that mapping.

    The totality proof runs. `theStopReasonSwitchHoldsOneArmPerWireCaseAndNoDefault` reads the shipped `ExitCode.swift`, takes the lines between the switch head and its close, and compares them with the six arms. A `default` arm would fail it, and the doc comment on `init(stopReason:)` states what the missing `default` buys: a seventh wire case fails the build with "switch must be exhaustive" instead of exiting 0 without a word.

    Two things I found on the way.

    `ScriptedInterruptWatch` is new test support. `InterruptTests` held a private fact-armed watch installer and `ExitCodeTests` needs the same one for the cancelled row. A second copy would have been a duplicate, so the installer now stands in one file and `InterruptTests` calls it.

    `ValidationError` is the direct way to drive the usage row. The ArgumentParser `MessageInfo.init(error:type:)` maps a bare `ValidationError` to `validationFailure`, a thrown `ExitCode` to itself with an empty message, and any other error to `failure`. So `ExitCodeTests` drives the 2 row with a real error and needs no parse.
  timestamp: 2026-09-07T22:33:49.746560+00:00
- actor: claude-code
  id: 01m1z0dydd0rppbdkqjpwt9w81
  text: |
    ### review — findings
    - evidence: 1 finding, 1 confirmed, 0 refuted. Scope: `review sha HEAD~1..HEAD` (commit 8dde05d). File: Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift:113
    - next: Correct the parameter documentation name in the whole file, then do the review again.
  timestamp: 2026-09-07T22:39:41.485962+00:00
- actor: claude-code
  id: 01m1z0e818bvhcr2nmg2fm1b19
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 files, ExitCode.swift new, the two exit-code literals deleted
    - test: green — swift test, 484 tests in 50 suites, one known issue (baseline 474 in 49)
    - commit: 8dde05d
    - review: findings — Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift:113 (documentation/parameter-name)
  timestamp: 2026-09-07T22:39:51.336301+00:00
- actor: claude-code
  id: 01m1z0gt3w9vw68y1w3nbhh65c
  text: |
    ### implement — changed

    - evidence: 1 file — `Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift`. `swift build` completes with no warning. `swift test` gives 484 tests in 50 suites, all passed, with the one known issue at `HarnessSmokeTests.swift:239`. That is the baseline.
    - next: `/review`

    The finding: the parameter documentation of `exitCode(ofTurnPlaying:label:interruptedAfter:)` named the external label `interruptedAfter` where the internal name `arrivedText` belongs. Swift-DocC and Xcode resolve a documentation entry against the internal name, so the entry pointed at no parameter.

    To remove the cause from the whole file, I read every `- Parameter` and `- Parameters` entry in `ExitCodeTests.swift`. The file holds two documentation blocks with parameters, and four entries in total:

    - `script` — the internal name of `ofTurnPlaying script:`. Correct.
    - `label` — the label and the internal name are the same word. Correct.
    - `arrivedText` — the internal name of `interruptedAfter arrivedText:`. This was the one entry that named the label, and it is now corrected.
    - `source` — the internal name of `of source:` on `switchArms(of:)`. Correct.

    So one entry changed. The paragraph that follows the entry is re-flowed to the wrap width the file holds, because the shorter first word left a short line.
  timestamp: 2026-09-07T22:41:15.388074+00:00
depends_on:
- 01M1MP0MQ6VHRR004FQQEADS6C
position_column: doing
position_ordinal: '80'
title: 'Exit codes: one table for every stop reason and failure'
---
## What

cli-plan.md §5.8. "Nonzero" is not enough for a script. Add
`Sources/acp-agent/ExitCode.swift` with one enum, and use it at every
exit.

| Code | Meaning |
|---|---|
| 0 | `end_turn`, or a report that ran |
| 1 | An error: configuration, spawn, protocol, or I/O. `doctor` found an error. |
| 2 | A usage error |
| 3 | `refusal` |
| 4 | `cancelled` |
| 5 | `doctor` found warnings, and no error |

**Code 124 is not in the agent's table.** cli-plan §5.8 lists it, but
§5.4 gives `run` no `--timeout` option, so no code path can produce it.
An acceptance criterion of "one assertion per row" would be
unsatisfiable. 124 stays in the **client** CLI's table, where
`--timeout` exists. This card supersedes that row of §5.8 for the agent.

Map each `StopReason` of the wire to its code in **one total switch**,
with no `default` case, so a new stop reason upstream makes the build
fail rather than silently exiting 0. ArgumentParser's own usage error
maps to 2.

The reason line goes to **stderr**, never to stdout.

**This card lands before the exit-producing cards.** The progress card
adds a resolution-failure path and the doctor card adds 1 and 5; both
depend on this enum existing, so both list it as a dependency.

- [x] `ExitCode.swift`, with the six cases
- [x] A total switch over `StopReason`, with no `default`
- [x] The ArgumentParser usage error maps to 2
- [x] Every exit path in `Run` and `Acp` uses the enum

## Acceptance Criteria

- [x] A scripted `end_turn` gives 0, `refusal` gives 3, `cancelled`
      gives 4.
- [x] An unknown flag gives 2, with stdout empty.
- [x] A configuration that fails to load gives 1, with the reason on
      stderr.
- [x] The `StopReason` switch has no `default` case.
- [x] The enum declares no 124 case in this package.

## Tests

- [x] `ExitCodeTests`: one assertion per row of the six-row table,
      driven through the scripted model where a stop reason is
      necessary.
- [x] A test asserts stdout is empty for each nonzero exit.
- [x] A compile-time proof that the `StopReason` switch is total: adding
      a case to the wire enum must break the build, not the behavior.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Notes

The type is named `AgentExitCode`, in the file `ExitCode.swift` the card
names. A type named `ExitCode` would shadow the ArgumentParser type that
the same files and the test files use, and every reference to either one
would then be ambiguous.

`RunTurnResult.stopReason` is optional, and a `nil` stop reason now
gives 1 where it gave 0 before. `nil` means the wire ended before an
idle update arrived, so the turn has no outcome to report, and a script
must not read that as a finished answer.

## Review Findings (2026-09-07 17:35)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift:113` `swift/doc-parameter-naming` — Parameter documentation names the external argument label `interruptedAfter`, but should name the internal parameter name `arrivedText`. Documentation entries must use the internal (local) parameter name that Swift-DocC and Xcode resolve against. Change `///   - interruptedAfter:` on line 113 to `///   - arrivedText:` to match the internal parameter name.
