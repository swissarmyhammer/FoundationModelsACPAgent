---
assignees:
- claude-code
depends_on:
- 01KYSVEH19FKV250W4KQG1RFCT
- 01KYSVCAH5MAEMCH4R5A8MNCSF
position_column: todo
position_ordinal: '9980'
title: Examples/acp-agent and the gated tier-3 stdio contract test
---
## What
Plan.md §20.2 + §17. One executable, two purposes: the family-convention example AND the tier-3 fixture.

- `Examples/acp-agent/main.swift` — small enough to read in one sitting; the composition is the lesson: choose the dotfolder name (`RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)`), serve `AgentSideConnection(stream: .stdio, logger: .standardError)`, `connection.run()`. Must show where a frontend appends its own tools to the merged roster. Must NOT grow argument parsing, rendering, or config wizardry. Full-duplex shape (never a read-request/write-response loop — that deadlocks on mid-turn updates, §20.2). Add the executable target to Package.swift.
- Tier-3 gated test `Tests/FoundationModelsACPAgentTests/Integration/StdioContractTests.swift` (env-var gated, e.g. `ACP_TIER3=1`): spawn the example as a subprocess; drive initialize → session/new → a prompt whose turn runs a real `shell` command that writes to ITS stdout; assert the protocol MUSTs (§17): agent stdout carries **only** ndJSON frames (child output must not leak — the shell capability captures, children do not inherit), no frame contains an interior newline, and framing survives the process boundary (every line parses as a JSON-RPC message).

- [ ] Example target compiles and serves stdio
- [ ] Frontend-tool-append seam shown
- [ ] Gated subprocess test spawning the example
- [ ] stdout-purity and no-newline assertions

## Acceptance Criteria
- [ ] `swift run acp-agent` starts and answers `initialize` over stdio (asserted by the gated test, not manually)
- [ ] With `ACP_TIER3=1`, the contract test passes: every stdout line parses as JSON-RPC; a subprocess `echo` during the turn never appears raw on agent stdout
- [ ] Without the env var, `swift test` skips the suite (still green)

## Tests
- [ ] The gated suite above; run `ACP_TIER3=1 swift test --filter StdioContract` → green locally
- [ ] Ungated `swift test` → green (suite skipped)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.