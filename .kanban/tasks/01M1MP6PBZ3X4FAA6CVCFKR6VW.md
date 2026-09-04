---
assignees:
- claude-code
depends_on: []
position_column: todo
position_ordinal: '9280'
title: 'acp-client N1+N2: the target, the subcommand tree, and run'
---
### What

Upstream work in `../FoundationModelsACPClient`. Its `cli-plan.md`
milestones **N1 and N2**. The later milestones are separate cards.

This card is the one that `--out-of-process` interop testing waits on,
so it must not be blocked by the doctor work.

**N1 — the target and the tree:**
- A new `acp-client` executable **target and product**. A product, so
  this package can depend on it and spawn it beside its own binaries.
- Declare `apple/swift-argument-parser` from 1.8.0 and
  `github.com/tuist/Noora`, pinned to the same exact version the agent
  package pins.
- `Sources/acp-client/Terminal/TerminalRenderer.swift` — the client's
  own renderer, matching the agent's: a spinner, a progress bar and a
  table, on **stderr only**, silent when the destination is not a
  terminal. Take the destination and the terminal test as injected
  values, so both paths are automated.
- The subcommand tree: `run` (default), `probe`, `doctor`, `--help`,
  `--version`. `probe`, `doctor` are stubs that exit 1 here.

**N2 — `run`:**
- `acp-client run <prompt> -- <agent-command> [args...]`. Everything
  after `--` is the agent command. The binary never splits a command
  string into words.
- With no `--`: usage error, exit 2, stdout empty.
- The prompt source, stdout, stderr and exit codes of the client plan
  §7 to §9.

It links this package, the wire, `ArgumentParser` and `Noora`. Never
Router, ACPAgent, MCP or the FoundationModels framework.

- [ ] N1: the target, the product, the two package dependencies
- [ ] N1: `TerminalRenderer`, with an injected destination and terminal test
- [ ] N1: the subcommand tree, with `probe` and `doctor` stubbed
- [ ] N2: `run` over `--`, and §7 to §9
- [ ] Merge to `main` in the client repository

### Acceptance Criteria

- [ ] `acp-client run "hi" -- <stub agent>` prints only the answer on
      stdout, byte for byte.
- [ ] A missing `--` gives a usage error and exit 2, with stdout empty.
- [ ] The agent arguments after `--` reach the agent unchanged, flags
      included.
- [ ] `TerminalRenderer` writes zero bytes when its injected destination
      is not a terminal, and draws when it is.
- [ ] `TerminalRenderer.swift` is the only file under
      `Sources/acp-client/` that holds `import Noora`.
- [ ] The exit codes match the shared table: 0, 1, 2, 3, 4.
- [ ] The change is on the client `main`.

### Tests

- [ ] The subcommand tree, and the missing-`--` usage error.
- [ ] The agent arguments after `--` reach the stub agent unchanged.
- [ ] The prompt-source table of the client plan §7, each row.
- [ ] The stub agent over stdio: stdout is only the answer text, byte
      for byte.
- [ ] `TerminalRenderer` against an injected non-terminal destination
      (zero bytes) and an injected terminal one (draws).
- [ ] A source-level test: exactly one file holds `import Noora`.
- [ ] `swift test` in `../FoundationModelsACPClient` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.