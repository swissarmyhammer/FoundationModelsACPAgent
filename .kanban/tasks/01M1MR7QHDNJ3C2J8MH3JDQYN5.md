---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m230b3zmn0jb124xbw215qk9
  text: |-
    ### The upstream card is made

    `FoundationModelsACPClient` card **`^9vkmz1f`** — "N5: the doctor subcommand for a foreign agent". It is in `todo` and carries the full specification of this card, written from the ACPClient view.

    The card also carries two facts this session measured, so the upstream work does not have to find them again:
    - The Extras `Doctorable` module is on Extras `main` at `55d6b04`, and a `main` branch dependency stays pinned by revision until `swift package update` runs.
    - Do NOT model "never answers" with a never-resumed `withCheckedContinuation`. That prints `SWIFT TASK CONTINUATION MISUSE` and leaves a suspended task. A stub that waits and answers late is cancellable and leaves nothing behind.

    This card stays open until that one is done and merged to ACPClient `main`.
  timestamp: 2026-09-09T11:55:06.612486+00:00
- actor: claude-code
  id: 01m238pz4s17cyq6t3tdkm7a41
  text: |
    ### Verification of the upstream work

    The upstream card `^9vkmz1f` is `done` in `../FoundationModelsACPClient`. The four commits `7c3757a`, `277e670`, `8cf79ba` and `144b168` are on ACPClient `main`, and `origin/main` points at `144b168`. I read the code and the tests. I made no change in that repository.

    **Where the work is.**
    - `/Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/AcpClientCore/AgentCommandDoctor.swift` — the one `Doctorable`, with the seven rows.
    - `/Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/AcpClientCore/DoctorCommand.swift` — the subcommand, the two output streams and the exit code.
    - `/Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/AcpClientCore/TerminalOutput.swift` — `doctorReport(_:)`, the Noora table and the plain path.
    - `/Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/Sources/AcpClientCore/ExitCode.swift` — `forDoctorStatus(_:)`.
    - Tests: `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/AgentCommandDoctorTests.swift`, `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/DoctorCommandTests.swift`, `Tests/FoundationModelsACPClientTests/AgentCommandDoctorTests.swift`, `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift`, and the stubs in `IntegrationTests/.../Support/StubAgents.swift`.

    **The seven checks, row by row.** `checkNamesInOrder` holds the seven names in report order. `runHealthChecks()` does not throw. A row that could not run becomes a `warning` that names the row to repair first.

    1. The command exists and is executable — `resolver.resolve(command)`; a failure gives an `.error` that names the command. Tests: `eachResolutionFailureNamesItsOwnRepair` (unit, four resolution failures), `aCommandThatIsOnNoPathFailsTheFirstRow`.
    2. The process starts and stays — `watch(agent, for: settleInterval)` reads the pid for 500 ms; an agent that goes away gives an `.error`. Test: `anAgentThatEndsAtOnceFailsTheSecondRow`.
    3. Valid ndJSON and nothing else on stdout — `AgentStandardOutputReading` judges every whole line the tee copied during the handshake. `firstLineThatIsNotJSON` gives an `.error` that quotes the offending line and tells the writer to send the banner to stderr. Tests: `aBannerOnStdoutFailsTheStandardOutputRow` (quotes the line), `aBannerOnStdoutIsAnErrorAndExitsOne` (the report holds the row and the line, exit 1).
    4. `initialize` answers inside the limit — `initializeOutcome(of:)` races the handshake against `timeLimit` and CANCELS it, so nothing is left running. The named limits are `defaultTimeLimit` 10 s, `settleInterval` 500 ms, `teardownInterval` 2 s. Tests: `aSilentAgentFailsTheInitializeRow` asserts the status, the limit in the message, the full status pattern of the seven rows, and `elapsed < runReturnBound` (20 s against a short row limit); `aSilentAgentReportsATimeoutAndExitsOne` asserts exit 1 and the limit in the report, inside the run bound of the binary.
    5. The protocol version — `protocolVersionCheck` names both versions. Test: `aWrongProtocolVersionFailsTheVersionRow`.
    6. The advertised capabilities are readable — the row compares the members the agent sent with the members this build decoded. Tests: eight, over dropped members, a null member, a member of the wrong shape, and the `authMethods` count.
    7. Teardown, and no child — the row closes stdin and waits for the process group to empty. Tests: `anAgentThatIgnoresAClosedStdinWarnsOnTheTeardownRow`, `anAgentThatLeavesAChildWarnsOnTheTeardownRow`, and three `noAgentProcessOutlivesTheChecks` tests.

    **The other acceptance criteria.**
    - Exit 0, 1 and 5 — `AcpClientExitCode.forDoctorStatus(_:)` maps `.ok` to `.success`, `.warning` to `.doctorWarning` (5) and `.error` to `.failure` (1). Tests: `eachFormGoesToItsOwnStreamAlone` (0), `aBannerOnStdoutIsAnErrorAndExitsOne` and `anAgentCommandThatIsOnNoPathExitsOne` (1), `anAgentThatOnlyLeaksExitsFive` (5, and the test also asserts the code is not 2).
    - `--json` decodes to the same checks the table shows — `theJSONFormDecodesToTheChecksThePlainReportDraws` decodes stdout into `DoctorReport`, asserts the names are `checkNamesInOrder`, and asserts that `PlainTextDoctorRenderer().render(decoded)` is byte for byte the plain run's report.
    - Every `.warning` and `.error` carries a non-nil `fix` — `everyFindingObeysTheFixRule` runs three doctors (a well-behaved agent, a silent agent, an unresolvable command) and asserts the rule on every row, and also that a passing row carries no fix. `everyErrorEntryOfTheJSONFormCarriesAFix` asserts the same on the JSON form.
    - No ANSI escape with a non-terminal destination — `aReportWrittenToAPipeHoldsNoEscape` runs the banner agent, whose report holds passing rows, an error row and a fix line, and asserts that neither stdout nor stderr holds byte `0x1B`.
    - The two streams — `eachFormGoesToItsOwnStreamAlone` runs both forms and asserts that the other stream stays empty.

    **The stub caution held.** `makeSilentAgent` is a shell script with a `read` loop that does nothing. It holds no continuation, it is cancellable, and it ends on EOF, so the teardown row still passes.

    ### Two amendments, and the reason for each

    1. **A silent agent gives `.error`, not `.warning`.** The upstream card records an owner decision of 2026-09-09: this changes the card, and not the code. An agent that never answers `initialize` is not usable, so the status is `.error` and the exit code is 1. `initializeCheck` reports `failed(...)` for `.timeLimitReached`, and the two tests above pin it. I changed the acceptance row and the test row of this card to say `.error`, and I added an `## Amendments` section that records the decision. The `.warning` verdict and exit 5 stay for the teardown row, because an agent that leaks is still usable.
    2. **The name of the terminal layer.** This card asked for the client's `TerminalRenderer`. That is the file name in THIS repository. The client repository has no file of that name: its terminal layer is `TerminalOutput.swift`, the one file that imports Noora. The report goes out through the new member `TerminalOutput.doctorReport(_:)`, which draws the same four columns (`Status`, `Check`, `Message`, `Fix`) and the same status marks the agent CLI draws. The behavior is the behavior this card asked for.

    ### One row ticked from the upstream ledger, and not from a run of mine

    The row **"`swift test` in `../FoundationModelsACPClient` passes"** is ticked from the upstream ledger, and NOT from a run I made. I ran no test in either repository. The upstream ledger on `^9vkmz1f` records, at commit `8cf79ba`: `swift test` 231 tests in 21 suites passed, 0 failures, 0 warnings, 0 skipped; and `swift test --package-path IntegrationTests` 94 tests in 13 suites passed, 0 failures, 0 warnings, 0 skipped.

    ### The Package.resolved subtask

    `Package.resolved` is in `.gitignore` in the ACPClient repository, in the root package and in the integration package, so no commit can show the pin. The upstream ledger records that `swift package update` ran in BOTH packages, and that both resolve `FoundationModelsExtras` at `main (55d6b04)`, which is the revision that carries the `Doctorable` surface. The integration package resolves that dependency on its own, and it stood at `09eed09` at first, which has no `Codable` on `DoctorReport`; the second update moved it. The subtask is ticked for the update, and the word "commit" is removed from it, because the file is ignored.

    Nothing in this repository changed but the text of this card.
  timestamp: 2026-09-09T14:21:23.481359+00:00
- actor: claude-code
  id: 01m238q4y3dax49zdq4vwxzf81
  text: |
    ### implement — changed

    - evidence: card text only, in `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/.kanban/tasks/01M1MR7QHDNJ3C2J8MH3JDQYN5.md` and `.jsonl`. All 4 subtasks, all 6 acceptance criteria and all 7 test items are ticked, 17 of 17. Verified by reading the upstream code and tests on ACPClient `main` at commits `7c3757a`, `277e670`, `8cf79ba` and `144b168`. No file in `../FoundationModelsACPClient` changed. No test ran; the `swift test` row is ticked from the upstream ledger, and the comment above says so.
    - next: `/review`. The card stays in `doing`. Nothing is committed; the orchestrator commits.
  timestamp: 2026-09-09T14:21:29.411607+00:00
depends_on:
- 01M1MNXE777J4XA3NJTP483A8W
- 01M1MR74AAC3HM74F26P39Z3BC
position_column: doing
position_ordinal: '80'
title: 'acp-client N5: the doctor subcommand for a foreign agent'
---
### What

Upstream work in `../FoundationModelsACPClient`, milestone **N5** of its
`cli-plan.md` §10. This is the only client milestone that needs the
Extras `Doctorable` module, so it is the only one blocked by it.

`acp-client doctor -- <agent-command>` answers one question about a
foreign agent: is it usable? One `Doctorable` conformance over an agent
command:

| Check | Catches |
|---|---|
| The command exists on `PATH`, or at the given path, and it is executable | A typing mistake, or a binary that was not built |
| The process starts, and it does not exit at once | A missing runtime, or a crash on start |
| It writes valid ndJSON, and nothing else, to stdout | An agent that prints a banner to stdout |
| `initialize` answers inside the time limit | An agent that hangs |
| The protocol version is one we support | A v1 agent, or a newer draft |
| The advertised capabilities are readable | A malformed `initialize` result |
| The process ends when its stdin closes, and it leaves no child | A leaked agent |

The third row is worth the command on its own: "the agent MUST NOT write
non-ACP content to stdout" is a protocol MUST, and an agent that breaks
it fails in a way that looks like a parsing bug in **our** client.

**Rendering.** The human table goes to stderr through the client's own
terminal layer when stderr is a terminal, and through the Extras
plain-text renderer when it is not. `--json` writes the report to
stdout. Exit 0, 1 or 5.

Every check carries a timeout. Name it in seconds. `doctor` must never
hang.

- [x] The `Doctorable` conformance, with the seven checks
- [x] The terminal and the plain rendering paths
- [x] `--json` to stdout, and the three exit codes
- [x] Refresh `Package.resolved` so the new Extras `Doctorable` surface
      is visible: a `main` branch dependency stays pinned by revision
      until `swift package update` runs

### Acceptance Criteria

- [x] A stub that writes a banner to stdout gives that row an `.error`.
- [x] A stub that never answers `initialize` gives a timeout `.error`
      inside the named limit, and the command does not hang.
- [x] A command that does not exist gives an `.error` naming it.
- [x] Exit 0 for all `.ok`, 1 for any `.error`, 5 for warnings only.
- [x] `--json` decodes to the same checks the table shows.
- [x] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

Two new stub agents are necessary, and both are a few lines: one that
writes a banner to stdout, and one that never answers.

- [x] The banner stub gives an `.error` on the ndJSON row.
- [x] The silent stub gives a timeout `.error`, and the test asserts
      the elapsed time is under the limit.
- [x] A nonexistent command gives an `.error`.
- [x] The three exit codes, one test each.
- [x] `--json` decodes and matches.
- [x] With a non-terminal destination the output holds no ANSI escape.
- [x] `swift test` in `../FoundationModelsACPClient` passes.

### Amendments

This card is a tracking card. The upstream card `^9vkmz1f` records two
owner decisions of 2026-09-09. The text above holds both.

1. **A silent agent gives `.error`, not `.warning`.** The owner decided
   that this changes the card, and not the code. An agent that never
   answers `initialize` is not usable, so the status is `.error` and the
   exit code is 1. Two rows above now read `.error`. The `.warning`
   verdict and exit 5 stay for the teardown row, because an agent that
   leaks is still usable.
2. **The name of the terminal layer.** This card said
   `TerminalRenderer`, which is the file name in THIS repository. The
   client repository has no file of that name. Its terminal layer is
   `TerminalOutput.swift`, the one file that imports Noora, and the
   report goes out through the new member `TerminalOutput.doctorReport(_:)`.
   The behavior is the one this card asked for: a table on a terminal,
   and the Extras plain text on a pipe or a file.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.