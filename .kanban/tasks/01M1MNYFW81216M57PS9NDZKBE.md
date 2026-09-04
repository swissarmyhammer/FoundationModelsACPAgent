---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Move acp-agent to Sources and give it an ArgumentParser subcommand tree
---
## What

cli-plan.md §5.1 and §5.3. The structural change every other CLI task
builds on.

1. Move `Examples/acp-agent/` to `Sources/acp-agent/`.
   `Examples/acp-print/` does NOT move and does not change.
2. `Package.swift`: declare
   `.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0")`.
   The floor matches Extras and the package is already resolved, so no
   new checkout. On the `acp-agent` target add **`ArgumentParser` and
   `FoundationModelsACPClient`** — cli-plan §8 requires the client
   dependency and nothing else adds it. Change the target `path` to
   `Sources/acp-agent`. The executable product keeps the name
   `acp-agent`.
3. Replace `main.swift` with an `@main` `ParsableCommand` tree:
   `AcpAgentCommand` with `defaultSubcommand: Run.self`, `version:` set,
   and the subcommands `Run`, `Acp`, `Config`, `Instructions`, `Doctor`.
   `Run` takes an optional positional `prompt` plus the §5.4 options;
   every body is a stub that exits 1. Later tasks fill them.
4. **`AgentComposition.swift`** lands here, not in the `acp` card,
   because both `Run` and `Acp` need it: the `DotfolderName`, the
   `ConfigurationLoader` load, the `Router` with a `LiveModelLoader`,
   and the `RoutedACPAgent` construction, in one function.
5. **A deterministic model injection point.** Give `AgentComposition` an
   environment variable — `ACP_AGENT_STUB_MODEL=1` — that selects a
   deterministic echo model in place of `LiveModelLoader`. Without it no
   spawned-binary test can be written: `ScriptedModel` is in-process
   only, and the sole existing cross-process control is
   `TierThreeFixture`'s **real** SmolLM-135M, whose sampling is not
   reproducible. The out-of-process and interrupt cards both depend on
   this.

**This card breaks the tier-3 suite, on purpose.** Once `Run` is the
default subcommand, bare `acp-agent` on a piped stdin reads stdin as a
prompt instead of serving ndJSON, so
`IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/StdioContractTests.swift:269`
(`AgentProcess(command: command.path)` with no arguments) fails. Fix it
here: pass the `acp` argument in that spawn. Note that there is **no**
`ACP_TIER3` gate — `TierThreeFixture.swift` says the nested package is
the gate, and the root `swift test` never sees those targets.

- [ ] Move the directory; update `Package.swift` path and product
- [ ] Declare `swift-argument-parser`; link it and the client package
- [ ] The command tree with stub bodies, `--help`, `--version`
- [ ] `AgentComposition.swift`, with the stub-model environment switch
- [ ] Pass `acp` in the `StdioContractTests` spawn

## Acceptance Criteria

- [ ] `swift build` succeeds; `swift run acp-agent --help` prints usage
      to stdout and exits 0; `--version` prints a version and exits 0.
- [ ] `Package.resolved` gains no new package.
- [ ] `Examples/acp-print/main.swift` is byte-identical to its state
      before this task.
- [ ] `swift test --package-path IntegrationTests` passes, with
      `StdioContractTests` spawning `acp-agent acp`.
- [ ] With `ACP_AGENT_STUB_MODEL=1`, `acp-agent` composes a
      deterministic echo model and loads no weights.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift`: parse
      each form of §5.3 with `AcpAgentCommand.parseAsRoot(_:)` — a bare
      prompt gives `Run`, `acp` gives `Acp`, `run doctor` gives `Run`
      with `prompt == "doctor"`.
- [ ] An unknown option exits 2 and writes to stderr, with stdout empty.
- [ ] `AgentCompositionTests`: with `ACP_AGENT_STUB_MODEL=1` the
      composition returns the echo model, and two runs of one prompt
      give byte-identical text.
- [ ] `swift test` and `swift test --package-path IntegrationTests` both
      pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.