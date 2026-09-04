---
assignees:
- claude-code
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: todo
position_ordinal: '8580'
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

- [ ] `AcpCommand.swift` over the shared composition
- [ ] The keep-alive and the stdin-EOF lifecycle
- [ ] `acp` declares no `--cwd`
- [ ] The per-session project layer test below

## Acceptance Criteria

- [ ] `swift run acp-agent acp` serves ACP over stdio, as the old binary
      did.
- [ ] `swift test --package-path IntegrationTests` passes, with
      `StdioContractTests` unchanged from `9ndzkbe`.
- [ ] `acp-agent acp --cwd /tmp` is a usage error, exit 2.
- [ ] No log line reaches stdout in `acp` mode.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift`:
      `--cwd` on `acp` is a usage error, exit 2.
- [ ] **cli-plan §9's per-session layer row, which no other card owns.**
      An in-process test opens two sessions against one agent, with two
      temporary directories that hold different `config.yaml` files, and
      asserts each session resolved its **own** project layer — and that
      neither took the process working directory. This proves the §5.10
      "two loads" rule.
- [ ] **cli-plan §9's same-answer row, in process.** With
      `ACP_AGENT_STUB_MODEL=1`, a turn driven over
      `InMemoryTransport.pair()` and a turn driven over a stdio pair give
      byte-identical answer text. This is an ordinary test, not a
      spawned-binary one.
- [ ] `swift test` and `swift test --package-path IntegrationTests` both
      pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.