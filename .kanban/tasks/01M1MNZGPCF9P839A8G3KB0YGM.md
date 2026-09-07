---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1wh7efx639a25km5s2hxdet
  text: |-
    Research notes for this card.

    `9ndzkbe` already wrote the `Acp` body over `AgentComposition`, so the
    open work was the stdin-EOF half of the lifecycle and the four tests.

    Discoveries:

    - `AgentSideConnection` consumes the transport's inbound stream itself
      and reports no close to its agent. `Connection` takes an `onClose`
      handler, but `AgentSideConnection.init` does not pass one on. So the
      end of stdin is observable only in front of the connection. The old
      keep-alive slept for an hour at a time and never watched for it, so
      the process outlived a client that closed stdin without killing it.
      `Sources/acp-agent/InboundEndTransport.swift` is the answer: it
      forwards every chunk unchanged and reports the end.
    - `StdioTransport` binds to `STDIN_FILENO` and `STDOUT_FILENO`, and one
      process has one of each, so it cannot make a pair in process. The
      same-answer row of cli-plan §9 therefore needed a descriptor-backed
      pair: `PipeTransport` over two `Pipe` values, in
      `Tests/FoundationModelsACPAgentTestSupport/HarnessWire.swift`.
    - `AgentClientHarness` hard-wired `InMemoryTransport.pair()`. It now
      takes a `HarnessWire`, which defaults to the in-process pair, so every
      existing caller is unchanged.
    - `compaction.toolOutputLimit` is the key the per-session layer proof
      uses. It is inert: it selects no model and no tool, so the value a
      session resolved says which project layer that session read and
      nothing else.
    - `SessionSetupTests.twoConcurrentSessionsReadDifferentProjectLayerConfig`
      already proved two sessions read two layers over a hand-made stub
      agent. It does not prove the third value, the one the process started
      in, which is what §5.10's "two loads" rule needs, and it does not go
      through `AgentComposition`. The new test does both.
  timestamp: 2026-09-06T23:35:31.069864+00:00
- actor: claude-code
  id: 01m1wh9net5swp1tnx6zchz3k7
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/acp-agent/InboundEndTransport.swift (new),
      Sources/acp-agent/AcpCommand.swift,
      Tests/FoundationModelsACPAgentTestSupport/HarnessWire.swift (new),
      Tests/FoundationModelsACPAgentTestSupport/Harness.swift,
      Tests/FoundationModelsACPAgentTests/Support/ComposedTurnFixture.swift (new),
      Tests/FoundationModelsACPAgentTests/AcpCommandTests.swift (new),
      Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift,
      Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift
    - smoke: `acp-agent acp < /dev/null` now exits 0 in 0.13 s and writes
      zero bytes to stdout. Before the change the keep-alive slept for an
      hour and the process stayed. A hand-sent `initialize` frame over a
      pipe that stays open gets its framed answer back on stdout.
    - note: a request whose frame is followed at once by stdin EOF loses its
      answer, because `Connection.readLoop` calls `shutDown()` at EOF and
      `shutDown()` cancels every in-flight inbound handler. That is the wire
      package's own behavior and it stands with or without this change.
    - next: test
  timestamp: 2026-09-06T23:36:43.738408+00:00
- actor: claude-code
  id: 01m1wmx7ptp0qm8s9wjfv1kbg7
  text: |-
    ### test — green
    - `swift build`: complete, no error and no warning of this package.
    - `swift test` (root): 395 tests in 39 suites passed, with the one
      pre-existing `withKnownIssue` at HarnessSmokeTests.swift:239.
    - `swift test --package-path IntegrationTests`: 28 tests in 7 suites,
      3825 s. `StdioContractTests`, `ClientServerTests`, `CLIProcessTests`,
      `EvaluatorHonestyTests`, `PythonCLISubjectTests` and
      `PythonCLIDatasetTests` all passed. `PythonCLIEvaluationTests` failed
      with 4 issues, each `Expectation failed: mean >= pythonCLIEvalMeanFloor`
      at PythonCLIEvaluation.swift:335 — the known live-model zero-token
      defect ^pez780d, outside this card. Every sample reports `tokens=0/0`.
    - exceptions recorded: the two above. No other failure and no warning.
    - next: commit
  timestamp: 2026-09-07T00:39:50.746605+00:00
- actor: claude-code
  id: 01m1wn4z10ec9zmwap7jza2dve
  text: |-
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (commit 5e6a546), 8 files reviewed.
    - counts: 1 finding, 1 confirmed, 0 refuted, 7 attempted, 0 failed.
    - 1 finding — Tests/FoundationModelsACPAgentTestSupport/HarnessWire.swift:20
      `code-hygiene/disallowed-constructs-swift` no_unchecked_sendable.
    - next: implement

    ### finish iteration 1 — findings
    - implement: the stdin-EOF lifecycle in `Acp.run()` over the new
      `InboundEndTransport`, the `HarnessWire` transport pair with its
      `PipeTransport` ends, the shared `ComposedTurnFixture`, and the four
      tests the card asks for.
    - test: green. Root 395 tests passed with the pre-existing known issue at
      HarnessSmokeTests.swift:239. Nested 28 tests, only
      `PythonCLIEvaluationTests` failed on the known ^pez780d zero-token
      defect. Both are recorded exceptions.
    - commit: 5e6a546 feat(cli): end the acp server when stdin ends, and
      prove the two loads
    - review: 1 finding, on the `@unchecked Sendable` of `PipeTransport`.
  timestamp: 2026-09-07T00:44:04.000232+00:00
- actor: claude-code
  id: 01m1wvp612gdabefg4par5hj7q
  text: |-
    ### finish iteration 2 — done
    - implement: `PipeTransport` takes a plain `Sendable` conformance. Every
      stored property is already `Sendable`, so the `@unchecked` bought
      nothing, and the doc comment now states the one invariant that
      matters. `HarnessWire.swift` holds no other `@unchecked Sendable`, so
      the cause is gone from the whole file.
    - test: green. Root 395 tests in 39 suites passed with the pre-existing
      known issue at HarnessSmokeTests.swift:239. Nested 28 tests in 7
      suites, 6690 s: `StdioContractTests`, `ClientServerTests`,
      `CLIProcessTests`, `EvaluatorHonestyTests`, `PythonCLISubjectTests`
      and `PythonCLIDatasetTests` passed; `PythonCLIEvaluationTests` failed
      with the 4 known ^pez780d issues. Both exceptions recorded.
    - commit: 1877e82 refactor(test-support): give PipeTransport a plain
      Sendable conformance
    - review: clean. 0 findings over 7 attempted validators, and the prior
      finding is checked. The card moved to done.

    ### finish ledger — done
    - iterations: 2
    - commits: 5e6a546, 1877e82
    - open findings: 0 of 1
    - exceptions carried, both outside this card: the pre-existing
      `withKnownIssue` at HarnessSmokeTests.swift:239, and the live-model
      zero-token defect ^pez780d that fails
      `PythonCLIEvaluation.swift:335`.
    - what the card delivered: `acp-agent acp` now ends when stdin ends;
      `--cwd` on `acp` is a usage error, exit 2; the §5.10 "two loads" rule
      has an in-process proof; and `run` mode's in-process pair and the
      `acp` mode's ndJSON pipes give one byte-identical answer.
  timestamp: 2026-09-07T02:38:19.682563+00:00
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: done
position_ordinal: af80
title: 'acp subcommand: move the stdio server into the command tree'
---
## What

cli-plan.md §4 and §5.3. `9ndzkbe` already extracted
`AgentComposition.swift` and already passed the `acp` argument in the
tier-3 spawn. This card fills the `Acp` subcommand body.

In `Sources/acp-agent/AcpCommand.swift`:

- Call the shared `AgentComposition`.
- Open `AgentSideConnection(stream: .stdio, logger: .standardError)`,
  bind the connection into the agent, and hold the process open until
  stdin ends. There is no teardown handshake: the client owns the
  lifecycle (`plan.md` §17).
- Keep the two protocol MUSTs: stdout carries ndJSON frames only, and a
  shell child never inherits stdout.
- `acp` mode never reads stdin for a prompt — stdin is the wire (§5.5).
- **No `--cwd` on `acp`.** The client gives the working directory with
  each `session/new`, and a flag would fight the protocol (§5.10).

**A note on the test gate.** There is no `ACP_TIER3` environment gate.
`IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/TierThreeFixture.swift`
says it plainly: *"The suites carry no gate. This package is the gate:
the root `swift test` never sees these targets, and `swift test
--package-path IntegrationTests` runs them."* Use that boundary, and use
the real directory name — `FoundationModelsACPAgentIntegrationTests`,
not `IntegrationTests`.

- [x] `AcpCommand.swift` over the shared composition
- [x] The keep-alive and the stdin-EOF lifecycle
- [x] `acp` declares no `--cwd`
- [x] The per-session project layer test below

## Acceptance Criteria

- [x] `swift run acp-agent acp` serves ACP over stdio, as the old binary
      did.
- [x] `swift test --package-path IntegrationTests` passes, with
      `StdioContractTests` unchanged from `9ndzkbe`.
- [x] `acp-agent acp --cwd /tmp` is a usage error, exit 2.
- [x] No log line reaches stdout in `acp` mode.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift`:
      `--cwd` on `acp` is a usage error, exit 2.
- [x] **cli-plan §9's per-session layer row, which no other card owns.**
      An in-process test opens two sessions against one agent, with two
      temporary directories that hold different `config.yaml` files, and
      asserts each session resolved its **own** project layer — and that
      neither took the process working directory. This proves the §5.10
      "two loads" rule.
- [x] **cli-plan §9's same-answer row, in process.** With
      `ACP_AGENT_STUB_MODEL=1`, a turn driven over
      `InMemoryTransport.pair()` and a turn driven over a stdio pair give
      byte-identical answer text. This is an ordinary test, not a
      spawned-binary one.
- [x] `swift test` and `swift test --package-path IntegrationTests` both
      pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-06 19:40)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 0 not reviewed.

- [x] `Tests/FoundationModelsACPAgentTestSupport/HarnessWire.swift:20` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.