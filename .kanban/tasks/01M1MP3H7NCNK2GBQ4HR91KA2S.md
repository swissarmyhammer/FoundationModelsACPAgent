---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21xah4n71b468fy5gv266by
  text: |-
    Research done.

    Extras `Doctor` module, read at `.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/Doctor/`:
    - `Doctorable`: `doctorName`, `doctorCategory`, `isApplicable` (default `true`), `runHealthChecks() async -> [HealthCheck]`.
    - `HealthCheck`: `name`, `status`, `message`, `fix`, `category`, with `.ok`, `.warning` and `.error` factories.
    - `DoctorReport(checks:)`: `worstStatus`, `exitCode` (0, 1, 5), `Codable` as a plain array through a single-value container.
    - `DoctorRunner(components:)`, `run()`: concurrent, order stable by component position.
    - `PlainTextDoctorRenderer().render(_:)` gives text with no ANSI escape; a report with no check gives an empty string.
    - `DoctorReport.jsonData(prettyPrinted:)` encodes the array.

    This package, current state:
    - `Sources/acp-agent/DoctorCommand.swift` holds a stub that throws `NotImplementedError`.
    - `TerminalRenderer(destination:isTerminal:)` takes both as arguments, and its `table(statusHeader:columnHeaders:rows:)` draws nothing when `isTerminal` is `false`. `Tests/.../Support/TerminalCapture.swift` gives a pipe for both streams, so no test needs a pseudo-terminal.
    - `AgentExitCode` already carries the rows 0, 1 and 5 (`success`, `error`, `doctorWarnings`) and `parserError`.
    - `WorkingDirectoryOptions` gives `--cwd`.

    Plan: `Doctor` becomes an `AsyncParsableCommand` with `--cwd` and `--json`. A registry function gives the components, empty for now. One write function takes the report, the `--json` flag, a `TerminalRenderer` and the stdout handle, so a test injects a pipe for each stream.
  timestamp: 2026-09-09T01:43:07.157543+00:00
- actor: claude-code
  id: 01m21xpk1e8pnw303d3ynsx8k4
  text: |-
    Implementation landed, TDD.

    RED first: `DoctorCommandTests.swift` was written before any production change, and `swift build --build-tests` refused it with "type 'AcpAgentCommand.Doctor' has no member 'components'", "has no member 'write'", "no member 'asJSON'", "no member 'workingDirectoryOptions'", and "no exact matches in call to initializer" for `AgentExitCode(doctor:)` — 15 compile errors, one for each new surface the tests ask for. GREEN after the implementation, with no test changed.

    What the command looks like:
    - `AcpAgentCommand.Doctor` is now an `AsyncParsableCommand` with `--cwd` and `--json`.
    - `Doctor.components(workingDirectory:environment:)` is the registry. It gives `[]`, and it does not throw: a component reports a failure as a `HealthCheck` with the `error` status, because `doctor` must run every check and one broken component must not hide the rest. Each later card appends its conformance there and touches nothing else.
    - `Doctor.write(_:asJSON:renderer:standardOutput:)` holds the three exclusive paths — JSON to the stdout handle, the drawn table to the renderer, the Extras plain text to the renderer's destination — and takes both destinations as arguments, so each test injects a pipe for each stream.
    - `AgentExitCode.init(doctor:)` maps `worstStatus` to `success`, `error` and `doctorWarnings` through a switch with no `default`. Each exit-code test also asserts `AgentExitCode(doctor: report).rawValue == report.exitCode`, so this table and the Extras table cannot drift.
    - The table columns are Status, Check, Message, Fix.

    Two side effects, both necessary:
    - `doctor` was the last stub subcommand, so `NotImplementedError` had no caller left. Dead code is a blocker, so `Sources/acp-agent/NotImplementedError.swift` is deleted, and `CLIParsingTests.aStubBodyExitsOneWithItsNameOnStderr` — which asserted that `doctor` exits 1 with that text — is replaced by `noSubcommandOfTheTreeIsAStub`, which runs `doctor` through the same path and asserts nothing is thrown.
    - The `ExitCodeTests` header said the `5` row waits for the doctor card. It now points at `DoctorCommandTests`.

    On the `Package.resolved` subtask: the pin was already refreshed earlier in this session, `swift build` is clean over the Extras `Doctorable` surface, and the compiled `import FoundationModelsExtras` is the proof that the pinned revision carries it. This step is forbidden to stage or commit `Package.resolved`, so the file stays in the working tree for the commit step.

    One thing the next agent should watch: `components(workingDirectory:environment:)` does not read either parameter yet, because the registry is empty. The parameters stand so the later check cards do not have to change the command. Periphery may report them as unused parameters. Do not delete them — that would break the "this command never changes again" contract the card states.

    Note on formatting: this repository carries no `.swift-format` file, so there is no configured formatter to run. The new files were checked against `swift-format` at 4-space indentation and a 100-column line length, which is the shape the surrounding files hold, and both new files come back byte-identical.
  timestamp: 2026-09-09T01:49:42.318960+00:00
- actor: claude-code
  id: 01m21xpqt6g9nvg6ksgj2n1y1v
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/acp-agent/DoctorCommand.swift, Sources/acp-agent/ExitCode.swift, Sources/acp-agent/NotImplementedError.swift (deleted), Tests/FoundationModelsACPAgentTests/DoctorCommandTests.swift (new), Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift, Tests/FoundationModelsACPAgentTests/ExitCodeTests.swift. `swift test`: 508 tests in 53 suites passed, 1 known issue at HarnessSmokeTests.swift:239, which is the baseline. Before: 497 tests in 52 suites.
    - next: /review
  timestamp: 2026-09-09T01:49:47.206322+00:00
- actor: claude-code
  id: 01m21xzkcazjwxtkga1fpje3qc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (8cf7170); 6 files reviewed; 0 findings, 0 confirmed, 0 refuted, 7 rules attempted, 0 failed. The 4 .kanban files are excluded by .reviewignore. Five code-hygiene rules declined the deleted file Sources/acp-agent/NotImplementedError.swift; a deleted file has no code to judge.
    - next: none. The card moves to done.
  timestamp: 2026-09-09T01:54:37.578857+00:00
- actor: claude-code
  id: 01m21y07q869qpkq66py2q33fk
  text: |-
    ### finish iteration — clean
    - implement: changed — 6 files. `AcpAgentCommand.Doctor` (new `Sources/acp-agent/DoctorCommand.swift`) with `--cwd` and `--json`; `components(workingDirectory:environment:)` as the check registry, empty for now and never throwing, because a component reports its own failure as an `error` HealthCheck and `doctor` must run every check; `write(_:asJSON:renderer:standardOutput:)` with both destinations injectable; `AgentExitCode.init(doctor:)` mapping `worstStatus` through a switch with no `default`. `NotImplementedError.swift` deleted, because `doctor` was the last stub subcommand.
    - test-first: the new tests refused to compile with 15 errors before the implementation, and no test was changed to make them pass.
    - test: green — swift test, 508 tests in 53 suites, 1 known issue at HarnessSmokeTests.swift:239. It was 497 in 52 suites before this card.
    - commit: 8cf7170
    - review: clean — 0 findings, 7 rules attempted, 6 files reviewed
    - note for the check cards that follow: the `workingDirectory:` and `environment:` parameters of `components(...)` are not read yet. They stand on purpose, so a later check card does not have to change the command signature. Do not delete them.
  timestamp: 2026-09-09T01:54:58.408528+00:00
depends_on:
- 01M1MNXE777J4XA3NJTP483A8W
- 01M1MNXY19R8HPEMNGF2WXB0G6
- 01M1MNYFW81216M57PS9NDZKBE
- 01M1MP13QK1NX440VP88F7NQYA
position_column: done
position_ordinal: c680
title: 'doctor subcommand: run the checks, render the report, exit 0, 1 or 5'
---
### What

cli-plan.md §5.12. `doctor` answers one question: will this
configuration actually work? This card builds the command and the
rendering. The checks are three later cards.

In `Sources/acp-agent/DoctorCommand.swift`:

- Collect this package's `Doctorable` components through a registry
  function, run them through the Extras `DoctorRunner`, and render the
  `DoctorReport`.
- **Two rendering paths, and this resolves a contradiction in the
  plans.** `TerminalRenderer` is silent when its destination is not a
  terminal, but doctor-plan §6 requires "a pipe gets plain text, in a
  stable, testable form". A silent renderer cannot produce a piped
  table. So:
  - stderr **is** a terminal → draw the table through
    `TerminalRenderer`, with color and box drawing.
  - stderr is **not** a terminal → write the **Extras plain-text
    renderer** output. Plain text, no ANSI escape, still on stderr.
  The doctor table is therefore carved out of the silent-on-pipe rule,
  and the carve-out is deliberate: a diagnostic that vanishes in a pipe
  is useless in CI.
- `--json` writes the report to **stdout** as one JSON array.
- Exit 0 for all `.ok`, 1 for any `.error`, 5 for warnings with no
  error.
- It honors `--cwd`.

Register an empty component list here. Each later card appends its own
conformance to the registry, so this command never changes again.

- [x] `DoctorCommand`, over the Extras runner
- [x] The terminal path and the plain path, both on stderr
- [x] `--json` to stdout
- [x] The three exit codes, from the shared `ExitCode` enum
- [x] A registry function the later cards append to
- [x] Refresh and commit `Package.resolved`, so the new Extras
      `Doctorable` surface is visible — a `main` branch dependency stays
      pinned by revision until `swift package update` runs

### Acceptance Criteria

- [x] With an empty component list, `doctor` exits 0 and prints an empty
      report.
- [x] A stub component reporting `.error` exits 1; warnings only exits 5.
- [x] With a non-terminal stderr, the output is non-empty **and** holds
      no `ESC[` sequence.
- [x] With a terminal stderr, the output is drawn through
      `TerminalRenderer`.
- [x] `--json` goes to stdout; the table never does.
- [x] `Package.resolved` names an Extras revision that carries
      `Doctorable`.

### Tests

- [x] `DoctorCommandTests`: inject stub components and assert the exit
      code of each of the three cases.
- [x] With an injected non-terminal destination, the plain output is
      non-empty and holds no `ESC[`.
- [x] With an injected terminal destination, the table is drawn.
- [x] A test asserts the human table goes to stderr and never to stdout,
      and that `--json` does the reverse.
- [x] The `--json` output decodes to the same checks.
- [x] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.