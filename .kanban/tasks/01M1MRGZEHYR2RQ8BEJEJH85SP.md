---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1yvensv2qdvdr304f88h42h
  text: |-
    Picked up. Research notes before the first test.

    **What the stream carries.** `RunTurn.collect` already reads the one
    `AsyncStream<SessionUpdate>` the turn subscribes to. The three event
    kinds the card names map to `toolCallUpdate`, `planUpdate` and
    `stateUpdate(.idle)`. `EventProjection.projectToolCall` sends the
    creation update with `title: .value(name)` and `status: .value(.inProgress)`;
    `projectToolStatus` sends each later update with a status and NO title,
    and `TerminalStream` sends a content-only update with no status either.
    So a tool line must hold a field the event omits. The writer remembers
    each title by `ToolCallId`, and writes `-` for a field no event carried.

    **The line grammar.** `tool <id> <status> <name>`, `plan <done>/<total>
    <current>`, `stop <reason>`. Every free text stands last, so a name that
    holds a space cannot break a parse. `ToolCallStatus`, `PlanEntryStatus`
    and `StopReason` each vend `wireValue`, so the status words are the wire
    words.

    **The error line stays where it is.** `AcpAgentCommand.exitAfterFailure`
    already writes `fullMessage(for:)` to stderr for every failure, and it is
    the one error writer of the binary. A second error writer in this card
    would print each failure twice, which the public-output-contract rule
    refuses. So `--quiet` turns the EVENT lines off and the error keeps its
    own path; the test proves both halves.

    **The bar off.** The download-progress card `^1PHVVD0307Y4Z29CGH83` is
    still open, so nothing builds a `TerminalRenderer` for the run yet.
    `EventVerbosity.drawsProgress` is the switch that card reads, and a test
    holds a renderer built with it to zero bytes under `--quiet` and to bytes
    without it.

    **Test material.** `wait` is one of the four default session tools
    (`ToolCatalogTests.defaultToolNames`), it takes `{}`, and it needs no
    model, so a scripted turn of two `wait` calls gives a two-tool-call turn
    with no weights. `TerminalCapture` stands in for stderr and
    `AnswerCapture` for stdout.
  timestamp: 2026-09-07T21:12:42.555998+00:00
- actor: claude-code
  id: 01m1yvwrsa214m6gkhwm742kyf
  text: |-
    ### implement — changed

    **What landed.**

    `Sources/acp-agent/EventLineWriter.swift` holds two types.
    `EventVerbosity` is the §5.7 setting: `quiet`, `normal`, `verbose`, made
    by `init(verbose:quiet:)` over the two flags of §5.4 with `--quiet`
    winning when both are given. It vends `drawsProgress` — the switch the
    download-progress card reads beside `isatty(STDERR_FILENO) == 1` — and
    `writesEventLines`. `EventLineWriter` is the projection: an injected
    `FileHandle`, a verbosity, and a `receive(_:)` that writes one line for a
    tool call update, a plan update and the idle state update, and nothing
    for any other update.

    The grammar, documented on the type:

        tool <toolCallId> <status> <name>
        plan <completed>/<total> <the task being worked on>
        stop <stop reason>

    Each free text stands last, so a tool name that holds a space cannot
    break a parse. `-` stands for a field the event did not carry. The status
    words and the stop reason are the wire words, so a line says what the
    protocol said.

    `RunTurn.answer`, `RunTurn.drive` and `RunTurn.collect` each take
    `reporting events: EventLineWriter`, defaulting to `.silent` — the null
    device at the quiet verbosity — so every earlier call site keeps its own
    silence. `collect` feeds the ONE update stream to both writers: the
    answer text to stdout, the event line to stderr. `RunCommand.Run` gains
    `eventVerbosity` and `eventLineWriter`, and `run()` hands the real one
    over `FileHandle.standardError`.

    **The one design decision to record.** The card asks that `--quiet` write
    "nothing but errors". `AcpAgentCommand.exitAfterFailure` is already the
    ONE error writer of the binary: it writes `fullMessage(for:)` to stderr
    for every failure of every subcommand. A second error writer inside the
    run would print each failure twice, which the public-output-contract rule
    refuses, and suppressing the first one would move the exit-code contract
    that card `^13QK1NX440VP88F7NQYA` owns. So `--quiet` turns the EVENT
    lines off and the error keeps its own path. `quietWritesOnlyTheError`
    proves both halves: the writer stays silent over the whole event stream,
    and `exitOutcome(for:)` still puts a run failure's message on stderr with
    a non-empty `fullMessage`.

    **The bar off.** Nothing builds a `TerminalRenderer` for the run yet —
    that is the open card `^1PHVVD0307Y4Z29CGH83`. `drawsProgress` is the
    switch it reads, and two cases hold it to the real renderer: a bar built
    with `isTerminal: EventVerbosity.quiet.drawsProgress` over a
    terminal-flagged capture draws zero bytes, and the same bar built with
    `.normal.drawsProgress` draws bytes. Both directions, so the case
    measures the flag and not a renderer that draws nothing.

    **Tests.** `Tests/FoundationModelsACPAgentTests/EventLineWriterTests.swift`,
    15 cases. Four events give four lines in order; the answer chunk and the
    running state update give none; a tool call update with no status and no
    title still gives its line with the absent-field mark; the name of a call
    reaches each later line of that call; no `ESC[` anywhere; `--quiet` and
    neither flag each write zero bytes; the two flags select the three
    verbosities and `run` parses them; a `--verbose` piped run of a turn that
    calls `wait` twice writes only projected lines, names exactly two tool
    call ids, ends on one `stop end_turn`, and never carries the answer text;
    the same turn with neither flag writes zero bytes to stderr; and stdout
    is byte-identical across the four flag combinations.

    **Where the tests came from.** They were written first and watched fail:
    `swift build --build-tests` reported `cannot find 'EventLineWriter' in
    scope` and `extra argument 'reporting' in call` before a line of the
    production file existed.
  timestamp: 2026-09-07T21:20:24.362004+00:00
- actor: claude-code
  id: 01m1yvwxjaaq1x1ed9fv8ftq2b
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/acp-agent/EventLineWriter.swift (new),
      Sources/acp-agent/RunTurn.swift, Sources/acp-agent/RunCommand.swift,
      Tests/FoundationModelsACPAgentTests/EventLineWriterTests.swift (new).
      `swift test` run three times in sequence: 457 tests in 47 suites
      passed, each run with the one known issue at
      Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift.
      The baseline was 442 in 46 suites, so this card adds 15 tests and one
      suite. `swift build` is clean, with no source warning.
    - next: review.
  timestamp: 2026-09-07T21:20:29.258196+00:00
- actor: claude-code
  id: 01m1yw79h5p56yh3v4w145fpvw
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 62aa9aa), 7 validators, 0 findings, 0 confirmed, 0 refuted, 0 failed. 4 files reviewed. The 4 `.kanban/` files are out of scope by an ignore rule.
    - the stdout contract: `EventLineWriter.write` writes only to `destination`. `RunCommand.eventLineWriter` gives `.standardError`, and the default `.silent` gives `.nullDevice`. No path gives file descriptor 1. `standardOutputIsIdenticalAcrossTheFourFlagCombinations` shows the same stdout bytes for the four flag pairs.
    - both directions: `--verbose` shows what is added by an equality with the full line list, and what is not added by the empty capture for the answer chunk and the running state. `--quiet` shows what is removed by the empty capture and the bar that is off, and what stays by the error path assertion.
    - the `--quiet` decision: correct. `AcpAgentCommand.exitAfterFailure` keeps the error path, so a quiet run writes nothing but the error, as the card asks. A second error writer would print each failure two times.
    - the tool-name memory: bounded. `toolNames` is in a struct, and `RunTurn.collect` makes a local copy that ends with the turn. One `run` is one turn, so the map holds only the tool call ids of that turn.
    - next: none. The card is done.
  timestamp: 2026-09-07T21:26:09.189303+00:00
- actor: claude-code
  id: 01m1yw8asxbev1bt36bk3v1nzm
  text: |
    ### finish iteration 1 — clean

    - implement: changed — 4 files. `Sources/acp-agent/EventLineWriter.swift` and `Tests/FoundationModelsACPAgentTests/EventLineWriterTests.swift` are new; `RunTurn.swift` and `RunCommand.swift` thread `reporting events: EventLineWriter` through, `.silent` by default, so every earlier call site keeps its silence. `EventVerbosity` is `quiet`, `normal`, `verbose`, and `--quiet` wins when both flags stand. The writer projects one line for a tool call update, a plan update and the idle state update, and nothing for any other update. The tests were written first: `swift build --build-tests` gave `cannot find 'EventLineWriter' in scope` before the production file existed.
    - test: three `swift test` runs in sequence, each 457 tests in 47 suites with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`. The baseline was 442 in 46 suites, so this card adds 15 cases and one suite. `swift build` gave no source warning.
    - commit: `62aa9aa` `feat(cli): write one stderr line for each session event of a run`
    - review: clean — 0 findings from 7 validators, 4 files reviewed.

    The review answered four questions against the code:

    1. No path gives an event line to file descriptor 1. `EventLineWriter` has one sink, and `destination` is a `let` set at construction. The two constructions are `.standardError` and `.nullDevice`. The failing path keeps the same destination, because `RunTurn` holds the outcome in a `Result` and tears the wire down before it rethrows. `standardOutputIsIdenticalAcrossTheFourFlagCombinations` shows the four stdout captures are equal to each other and to the scripted answer.
    2. Both directions are proven for both flags. The `--verbose` case asserts equality on the full line list, so it also shows that nothing extra is written.
    3. The `--quiet` reading is right. The flag stops the event lines and the progress bar, and `AcpAgentCommand.exitAfterFailure` keeps its own error path, which no `run` flag reaches. A second error writer would write each failure two times.
    4. The tool-name map is bounded. `RunTurn.collect` takes a value copy, and a `run` is one turn per process, so the map holds at most the tool call ids of that one turn and dies with the call.
  timestamp: 2026-09-07T21:26:43.261362+00:00
depends_on:
- 01M1MP01P7SV7C2S0S8QZ0A60T
- 01M1MNXY19R8HPEMNGF2WXB0G6
position_column: done
position_ordinal: ba80
title: '--verbose and --quiet: the session event lines on stderr'
---
### What

cli-plan.md §5.7, the half that is not the download bar. Split out of
the progress card because it is a separate concern: a projection of
session events into one line each, with its own tests.

In `Sources/acp-agent/EventLineWriter.swift`:

- `--verbose` writes the session events to stderr, one line each: the
  tool calls (name and status), the plan updates, and the stop reason.
  **In a pipe too** — this is a person asking to see the events, not
  decoration.
- `--quiet` writes nothing but errors, in a terminal too. It also turns
  off the download bar of the progress card.
- Neither option touches stdout. §5.6 stays byte-exact.
- Without either option, a successful run writes nothing to stderr.

The projection reads the same `SessionUpdate` stream the CLI already
consumes for the answer text. One line per event, stable and parseable,
with no ANSI escape — a piped `--verbose` run is something a person
greps.

- [x] `EventLineWriter`, with an injected destination
- [x] `--verbose`: one line per tool call, plan update and stop reason
- [x] `--quiet`: errors only, and the bar off
- [x] Neither option by default: stderr stays silent

### Acceptance Criteria

- [x] With `--verbose` and a pipe destination, a scripted turn that
      makes two tool calls writes exactly one line per event.
- [x] The `--verbose` output holds no `ESC[` sequence.
- [x] With `--quiet`, a run with a terminal destination writes nothing
      but an error.
- [x] With neither option and a pipe, a successful run writes zero bytes
      to stderr.
- [x] stdout is byte-identical in all four cases.

### Tests

- [x] `EventLineWriterTests`: a scripted event stream with two tool
      calls, one plan update and a stop reason gives four lines, in
      order.
- [x] The piped `--verbose` output holds no `ESC[`.
- [x] `--quiet` with a terminal destination writes only the error.
- [x] The default case writes zero bytes.
- [x] A test asserts stdout is byte-identical across all four flag
      combinations for one scripted turn.
- [x] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.