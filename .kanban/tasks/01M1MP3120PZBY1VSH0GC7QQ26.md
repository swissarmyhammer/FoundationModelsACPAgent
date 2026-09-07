---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ww42780sge1jrzjmc61e42
  text: |-
    ### research

    - `Sources/acp-agent/InstructionsCommand.swift` holds `Instructions.Eject` as a
      stub that throws `NotImplementedError`. `CLIParsingTests` already parses
      `instructions eject` to that type.
    - **`config init` has no overwrite guard yet.** It is a stub too, and its card
      (^m9pnerh / 01M1MP2M9PNERHG16X7A0SG4JN) is still in `todo`. So "reuse the same
      guard as `config init`" means: write the guard ONE time, in a shared place
      that `config init` takes later. New file `Sources/acp-agent/LayerFileWriter.swift`
      holds `LayerSelection` (`--user` / `--project`, an `EnumerableFlag`), the
      writer, and the two refusals.
    - The layer roots come from `AgentComposition.makeConfigurationLoader(...).stack`
      — the same construction `config show` and `config path` use. The writer picks
      the layer by `DotfolderStack.Source`, so no code repeats the path derivation.
    - `CommandReport` is the stdout/stderr value the reporting subcommands build,
      and a test reads the value instead of the process streams.
    - A thrown error exits 1 on stderr: `AcpAgentCommand.exitOutcome(for:)` gives
      `ExitCode.failure` for every error that is not a usage error.
    - `InstructionsAssembler` puts a `===== <path> =====` header above a file that
      came from disk, and no header above the compiled-in floor. So the assembled
      text after an eject is NOT byte-equal to the text before it: the body is
      equal, and the header is new. The tests assert the body and the path, and
      they do not repeat the private header format.
    - The `AGENTS.md` walk stops at the git root, or at the working directory when
      there is no git root. A `ConfigCommandFixture` workspace has no `.git`, so
      the walk finds no document and the assembled text stays clean.
  timestamp: 2026-09-07T02:45:54.536117+00:00
- actor: claude-code
  id: 01m1x19w44j45ab7saqkr7hzwm
  text: |-
    ### test — green

    - evidence: `swift build --build-tests` clean, no warning. `swift test` — 404
      tests in 40 suites passed, 1 known issue. `swift test --filter
      InstructionsEjectTests` — 9 tests passed.
      `swift test --package-path IntegrationTests` — 28 tests in 7 suites, 4 issues,
      `EXIT=1`, all of them in `PythonCLIEvaluationTests`.
    - exception 1 (root, pre-existing, outside this card): the one `withKnownIssue`
      at `HarnessSmokeTests.swift:239`.
    - exception 2 (nested, pre-existing, outside this card): every one of the 4
      issues is `PythonCLIEvaluation.swift:335:13: Expectation failed: mean >=
      pythonCLIEvalMeanFloor`, and every sample reports `tokens=0/0` — the live-model
      zero-token defect ^pez780d. The host then ended with signal 11. Card
      ^81216m5 records the same two symptoms together, and states that the suite
      composes its agent in process over `LiveModelLoader` and never runs the CLI.
      This card changes only the CLI command tree, so it cannot reach that suite.
    - The tier-3 suites that DO spawn the binary all passed: `CLIProcessTests`,
      `StdioContractTests` and `ClientServerTests`.
      `aStubSubcommandExitsOneAndSaysSoOnStderr` names `doctor`, which is still a
      stub, so removing the `instructions eject` stub does not touch it.
    - next: commit.
  timestamp: 2026-09-07T04:16:27.780546+00:00
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: doing
position_ordinal: '80'
title: 'instructions eject: write Instructions.md into a layer'
---
## What

cli-plan.md §5.3 lists `acp-agent instructions eject`, and no milestone
covered it. This task closes that gap.

`plan.md` §3.1 makes `Instructions.md` a compiled-in floor that a file in
the user or the project layer replaces **wholesale**, nearest layer
wins. A person cannot edit what they cannot see, so the CLI writes the
compiled-in text out for them.

In `Sources/acp-agent/InstructionsCommands.swift`:

```
acp-agent instructions eject [--user|--project] [--force]
```

- It writes the compiled-in `Instructions.md` into the chosen layer.
  `--project` is the default, matching `config init`.
- It refuses to overwrite an existing file, and it exits 1 with a
  message that names `--force`.
- It prints the path it wrote, to stdout.
- It honors `--cwd`.

The plan spells this `instructions eject`, and not
`instructions --eject` as `plan.md` §3.1 writes it, so that every
subcommand group reads the same way.

- [x] `instructions eject`, with `--user`, `--project` and `--force`
- [x] Reuse the same overwrite guard as `config init`
- [x] Print the written path to stdout

## Acceptance Criteria

- [x] After an eject, the assembler reads the written file in place of
      the compiled-in text, and the two are equal.
- [x] A second eject without `--force` exits 1 and changes no file.
- [x] The written path goes to stdout, and the refusal goes to stderr.
- [x] `--cwd` selects which project layer receives the file.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/InstructionsEjectTests.swift`:
      eject into a temporary stack, then assert that the instruction
      assembler's result is unchanged — the ejected file is byte-equal
      to the compiled-in floor.
- [x] Edit the ejected file, and assert the assembler now returns the
      edited text. This proves the wholesale-replace rule end to end.
- [x] The refuse-to-overwrite path, and the `--force` path.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.