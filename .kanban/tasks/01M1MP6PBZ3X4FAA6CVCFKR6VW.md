---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1wg2pz7am10d1mnh7ztk7hf
  text: |
    Research, before the code work.

    The client repository was already at `d93ac7f` on `main` with milestones N1
    to N6 written, and `cli-plan.md` §15 marks all six "Done". So almost every
    line of this card was already satisfied. I read each acceptance row against
    the code rather than trusting the plan.

    What is already there and proven:
    - The `acp-client` executable target AND product, the `AcpClientCore`
      library target AND product, `apple/swift-argument-parser` from 1.8.0 and
      `tuist/Noora` at `.upToNextMinor(from: "0.57.0")`, all in
      `Package.swift`.
    - `Sources/AcpClientCore/TerminalOutput.swift` is the ONE file that holds
      `import Noora`. It takes the terminal reading and the byte sink as
      injected values, and `TerminalOutputTests` drives both paths.
    - The subcommand tree, the prompt-source table of §7, the byte-for-byte
      stdout rule of §8, and the exit-code table of §9, each with tests.

    Two gaps, and both were in the TESTS and not in the code:
    1. No test drove the BUILT binary with no `--`. The unit suite proves the
       parser throws and that `AcpClient.processExitCode(for:)` answers 2, but
       a unit test cannot see which descriptor ArgumentParser then wrote to,
       nor the number the process finally exited with. The card asks for
       "exit 2, with stdout empty", and only a process test measures that.
    2. No test drove `--help` at all. §6 gives it stdout and exit 0, which is
       the opposite descriptor from the usage ERROR, so the same argument
       applies.

    Both are now in
    `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/SubcommandTreeTests.swift`.
    The missing-separator test runs over all three subcommands, because §6
    gives the three one grammar and a rule proven on `run` alone would leave
    `probe` and `doctor` free to take a default agent.

    Two notes on the card text, which the plan has moved past:
    - The card names `Sources/acp-client/Terminal/TerminalRenderer.swift`. The
      plan §5 names `Sources/AcpClientCore/TerminalOutput.swift` and says why
      the two packages hold the import in files of their own. The plan is
      later than the card, and the containment rule the card means is kept.
    - The card and plan §5 both say the file vends "a spinner, a progress bar
      and a table". The code vends the spinner alone. That is not an oversight
      I can close here: §8 holds this layer to stderr, while the `probe` and
      `doctor` reports — the only readers a table would have — go to stdout.
      A table added now would have no caller. Recorded as ^jzdgnny.
  timestamp: 2026-09-06T23:15:27.335735+00:00
- actor: claude-code
  id: 01m1wg5rvmkrnrb2mw7r3xptx5
  text: |
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsACPClient/IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/SubcommandTreeTests.swift. Two process-level tests: the missing `--` over all three subcommands (exit 2, stdout empty, stderr says why), and `--help` (exit 0, stdout names the three, stderr empty). No source of the binary changed: the behaviour was already correct, and the gap was in the tests.
    - next: test

    ### test — green
    - evidence: `swift build` clean; `swift test` — 227 tests in 20 suites passed; `swift test --package-path IntegrationTests` — 91 tests in 13 suites passed; `swift build --build-tests` in both packages — 0 source warnings. The agent package builds, and holds only the `.kanban/` change of this card.
    - next: commit
  timestamp: 2026-09-06T23:17:07.572555+00:00
- actor: claude-code
  id: 01m1wgd8wvb9mv069g6xgn0xde
  text: |
    ### commit — changed
    - evidence: 4f990f8 test(cli): prove the missing separator and --help at the process level, local on the client `main`. Nothing was pushed.
    - next: review

    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` in ../FoundationModelsACPClient — 1 file reviewed, 7 validators attempted, 0 findings, 0 refuted, 0 failed, 0 skipped. The card moved to `done`.
    - next: the ledger, and the `.kanban/` commit

    A note for the next agent, because this cost time. The `review` MCP tool of
    this session takes its repository root from the working directory the MCP
    server started in, which is the AGENT repository. It has no parameter that
    moves that root: an absolute path into the sibling repository is refused
    with "escapes the repository root", and a `cwd` argument is accepted and
    then ignored — the run reviewed the agent repository's own last commit.
    The `sah tool review ...` CLI route cannot stand in for it either: it is
    built with no agent factory, and it says so.

    The way that works is to start a SECOND `sah serve` in the repository that
    holds the code and to call the tool over its stdio. The driver used here is
    `scratchpad/mcp_review.py`: it spawns `sah serve` with that working
    directory, does the MCP handshake, and calls `review sha`. Any card whose
    code lives in a sibling repository needs the same.
  timestamp: 2026-09-06T23:21:13.371940+00:00
- actor: claude-code
  id: 01m1wgdgjpeb3g4pde87wzfbnw
  text: |
    ### finish iteration 1 — done
    - implement: changed. Read every acceptance row of the card against the client repository at `d93ac7f`, which already carried N1 to N6. Two rows had no test that could measure them, because both are claims about a file descriptor and a process exit code. Wrote `IntegrationTests/Tests/FoundationModelsACPClientIntegrationTests/SubcommandTreeTests.swift`: a missing `--` over all three subcommands (exit 2, stdout empty, stderr says why), and `--help` (exit 0, stdout names the three, stderr empty). The binary needed no change. Opened ^jzdgnny for the one card line the code does not meet: `cli-plan.md` §5 says the terminal file vends a progress bar and a table, and §8 leaves them no caller.
    - test: green. `swift test` — 227 tests in 20 suites passed. `swift test --package-path IntegrationTests` — 91 tests in 13 suites passed. `swift build --build-tests` in both packages — 0 source warnings. The agent package builds, and it holds only this card's `.kanban/` change.
    - commit: changed. 4f990f8 in the client repository, local on `main`. Nothing was pushed.
    - review: clean. `review sha HEAD~1..HEAD` in the client repository — 1 file reviewed, 7 validators attempted, 0 findings.
  timestamp: 2026-09-06T23:21:21.238873+00:00
depends_on: []
position_column: done
position_ordinal: ae80
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

- [x] N1: the target, the product, the two package dependencies
- [x] N1: `TerminalRenderer`, with an injected destination and terminal test
- [x] N1: the subcommand tree, with `probe` and `doctor` stubbed
- [x] N2: `run` over `--`, and §7 to §9
- [x] Merge to `main` in the client repository

### Acceptance Criteria

- [x] `acp-client run "hi" -- <stub agent>` prints only the answer on
      stdout, byte for byte.
- [x] A missing `--` gives a usage error and exit 2, with stdout empty.
- [x] The agent arguments after `--` reach the agent unchanged, flags
      included.
- [x] `TerminalRenderer` writes zero bytes when its injected destination
      is not a terminal, and draws when it is.
- [x] `TerminalRenderer.swift` is the only file under
      `Sources/acp-client/` that holds `import Noora`.
- [x] The exit codes match the shared table: 0, 1, 2, 3, 4.
- [x] The change is on the client `main`.

### Tests

- [x] The subcommand tree, and the missing-`--` usage error.
- [x] The agent arguments after `--` reach the stub agent unchanged.
- [x] The prompt-source table of the client plan §7, each row.
- [x] The stub agent over stdio: stdout is only the answer text, byte
      for byte.
- [x] `TerminalRenderer` against an injected non-terminal destination
      (zero bytes) and an injected terminal one (draws).
- [x] A source-level test: exactly one file holds `import Noora`.
- [x] `swift test` in `../FoundationModelsACPClient` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
