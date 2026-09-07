---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1x736n84sdwn766tfq0v7je
  text: |-
    Research, before the code.

    What is there now:
    - `Sources/acp-agent/RunCommand.swift` holds `Run`. `promptText()` is a
      `guard let prompt` only, and its doc comment says the stdin rows come
      with this card.
    - `Sources/acp-agent/RunTurn.swift` drives one turn over
      `InMemoryTransport.pair()`. `collect(from:)` joins the text of each
      `agent_message_chunk` and returns it in `RunTurnResult.answer`. Nothing
      streams.
    - `Sources/acp-agent/CommandReport.swift` writes the whole report to
      stdout at the end. `Run.report(...)` puts the answer there, so today
      the answer arrives in one block after the turn.

    The plan:
    - New `Sources/acp-agent/PromptSource.swift`: the four rows of the §5.5
      table, over an injected stdin handle and an injected `isTerminal`
      flag. The process form reads `isatty(STDIN_FILENO)`. The terminal row
      throws `ValidationError`, which ArgumentParser prints as the usage on
      stderr with exit 2.
    - New `Sources/acp-agent/AnswerWriter.swift`: `AnswerSink`, and an
      `AnswerWriter` over a raw file descriptor, `STDOUT_FILENO` by default.
      A raw `write(2)` carries no user-space buffer, so each chunk is on the
      descriptor when the call returns; that is the flush. A descriptor is
      `Sendable`, and the sink crosses into the collector task, so a raw
      descriptor also keeps the concurrency check honest.
    - `RunTurn.answer` takes the sink and feeds each chunk to it.
      `RunTurnResult` keeps the stop reason only: the text has one path now,
      and a second copy that only a test reads would be dead.
    - `Run` streams the answer and builds no stdout report, so stdout
      carries the answer bytes and nothing else.

    Tests: `PromptSourceTests.swift` (one test per row, a `Pipe` for the
    non-terminal rows), `AnswerWriterTests.swift` (`["a","b","c"]` gives
    `abc`), and a scripted-model test that the bytes on the descriptor equal
    the concatenated chunks.
  timestamp: 2026-09-07T05:57:40.648549+00:00
- actor: claude-code
  id: 01m1x9j4yktdwyvf2m3vkkb4gr
  text: |-
    Implementation landed, and one dead end is worth recording.

    What changed:
    - New `Sources/acp-agent/PromptSource.swift`: the four rows of §5.5. The
      memberwise form takes a stdin handle and an `isTerminal` flag, and the
      convenience `init(argument:)` in an extension reads
      `isatty(STDIN_FILENO)`. The convenience init stands in an extension so
      the synthesized memberwise init survives; a hand-written memberwise
      init is what `swiftformat`'s `redundantMemberwiseInit` removes.
    - New `Sources/acp-agent/AnswerWriter.swift`: `AnswerWriter` over a raw
      descriptor, `STDOUT_FILENO` by default, with a partial-write loop that
      retries on `EINTR`, and `AnswerWriteError`.
    - `RunTurn.answer` takes the writer and feeds each chunk to it.
      `RunTurnResult` keeps the stop reason only.
    - `Run.perform(environment:into:)` replaces `Run.report(environment:)`:
      the answer streams, and no stdout report is built.

    The dead end: the first `AnswerCapture` stood on a `Pipe`, and two call
    sites passed `AnswerCapture().writer` as a temporary. The capture died
    with the expression, the pipe closed, and the turn then wrote to a
    closed descriptor. `swift test` hung for 30 minutes and had to be
    killed. The capture now stands on a throwaway FILE, so a long answer
    cannot fill a buffer and block, and every call site holds the capture in
    a named `let` for the whole turn. The class doc says both reasons.

    No `AnswerSink` protocol: `AnswerWriter` is the one writer, and a
    protocol with one conformer is an abstraction with no second consumer.
    A struct over an `Int32` is `Sendable` on its own, which the collector
    task needs.
  timestamp: 2026-09-07T06:40:47.571501+00:00
- actor: claude-code
  id: 01m1x9jvhw776j78e0v1rqvzef
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/acp-agent/PromptSource.swift (new),
      Sources/acp-agent/AnswerWriter.swift (new),
      Sources/acp-agent/RunCommand.swift, Sources/acp-agent/RunTurn.swift,
      Tests/FoundationModelsACPAgentTests/PromptSourceTests.swift (new),
      Tests/FoundationModelsACPAgentTests/AnswerWriterTests.swift (new),
      Tests/FoundationModelsACPAgentTests/Support/AnswerCapture.swift (new),
      Tests/FoundationModelsACPAgentTests/RunCommandTests.swift
    - next: the test step
  timestamp: 2026-09-07T06:41:10.716608+00:00
- actor: claude-code
  id: 01m1xet4x4zwybfwaa5x79d5e9
  text: |-
    ### test — green
    - evidence: root `swift build && swift test`: 419 tests in 43 suites
      passed, 1 known issue at HarnessSmokeTests.swift:239 (the recorded
      exception). Nested `swift test --package-path IntegrationTests`: 28
      tests in 7 suites, 6 suites passed (PythonCLIDatasetTests,
      PythonCLISubjectTests, EvaluatorHonestyTests, CLIProcessTests,
      StdioContractTests, ClientServerTests);
      PythonCLIEvaluationTests failed with 4 issues at
      PythonCLIEvaluation.swift:335, every sample at `tokens=0/0` — the
      live-model zero-token defect `^pez780d`, which this card does not
      touch. The `missing creator for mutated node` line is a build-system
      message, not a source warning.
    - next: the commit step
  timestamp: 2026-09-07T08:12:32.548931+00:00
- actor: claude-code
  id: 01m1xetvg12b9m48se3vzgs977
  text: |-
    ### commit — changed
    - evidence: fc100fd `feat(run): read the prompt by the §5.5 table, and
      stream the answer to stdout` — 8 files, local only, nothing pushed.
    - next: the review step
  timestamp: 2026-09-07T08:12:55.681413+00:00
- actor: claude-code
  id: 01m1xezbdcccger6mw05nd6tcy
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 8 files reviewed, 0 not
      reviewed; counts findings=0, confirmed=0, refuted=0, attempted=7,
      failed=0. No prior findings section stood on the card.
    - next: the card moved to done; write the finish ledger
  timestamp: 2026-09-07T08:15:23.052740+00:00
- actor: claude-code
  id: 01m1xezkzzj0kcz7dj3yspe2d0
  text: |-
    ### finish iteration 1 — done
    - implement: changed — 8 files; new `Sources/acp-agent/PromptSource.swift`
      and `Sources/acp-agent/AnswerWriter.swift`, plus
      `Sources/acp-agent/RunCommand.swift`,
      `Sources/acp-agent/RunTurn.swift`, and the four test files.
    - test: green — root `swift build && swift test`: 419 tests in 43 suites
      passed with 1 known issue at HarnessSmokeTests.swift:239 (the recorded
      exception). Nested `swift test --package-path IntegrationTests`: 28
      tests in 7 suites; the 6 other suites passed, and
      PythonCLIEvaluationTests failed with 4 issues at
      PythonCLIEvaluation.swift:335, every sample at `tokens=0/0` — the
      live-model zero-token defect `^pez780d`, which this card does not
      touch.
    - commit: changed — fc100fd `feat(run): read the prompt by the §5.5
      table, and stream the answer to stdout`. Local only.
    - review: clean — `review sha HEAD~1..HEAD`, 8 files reviewed, findings=0,
      confirmed=0, refuted=0, attempted=7. The card moved to done.
  timestamp: 2026-09-07T08:15:31.839265+00:00
depends_on:
- 01M1MP01P7SV7C2S0S8QZ0A60T
position_column: done
position_ordinal: b280
title: 'run: the prompt source table and the stdout contract'
---
## What

cli-plan.md §5.5 and §5.6, in `Sources/acp-agent/RunCommand.swift` and a
new `Sources/acp-agent/AnswerWriter.swift`.

**Where the prompt comes from.** In `acp` mode stdin is the wire, and
that mode never looks at stdin for a prompt. In `run` mode:

| Condition | Result |
|---|---|
| A prompt argument | Use it. |
| No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
| No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
| The prompt is `-` | Read the prompt from stdin, a terminal included. |

Detect a terminal with `isatty(STDIN_FILENO)`. This gives
`echo "hello" | acp-agent`, which is what a person expects.

**stdout.** `AnswerWriter` writes each `agent_message_chunk` to file
descriptor 1 as it arrives, and it flushes each one. A local model is
slow, so a person must see the answer grow.

- Write the text **verbatim**. Add no trailing newline, and add no
  color, in a terminal and in a pipe alike. The output is data, and a
  rule that changes with a terminal cannot be tested byte for byte.
- stdout gets nothing more. Not a session id, not a token count, not a
  stop reason. Those go to stderr.

- [x] The four rows of the prompt-source table
- [x] `AnswerWriter`: write and flush per chunk, verbatim
- [x] Move every other message off stdout

## Acceptance Criteria

- [x] `echo "hi" | acp-agent` reads the prompt from stdin.
- [x] `acp-agent run` with a terminal stdin prints the usage to stderr
      and exits 2, with stdout empty.
- [x] `acp-agent run - < file` reads the file.
- [x] `acp-agent run "hi" > out.txt` gives a file whose bytes equal the
      concatenated chunks, with nothing added and nothing removed.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/PromptSourceTests.swift`: one
      test per row of the table, with a `Pipe` for the non-terminal
      cases.
- [x] `Tests/FoundationModelsACPAgentTests/AnswerWriterTests.swift`:
      given chunks `["a", "b", "c"]`, the captured stdout is exactly
      `abc` — no newline, no escape sequence.
- [x] An integration test with the scripted model asserts stdout is
      byte-identical to the concatenation of the scripted chunks.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.