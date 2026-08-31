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
Plan.md §20.2 and §17. One executable, two purposes: the family-convention example AND the tier-3 fixture.

- `Examples/acp-agent/main.swift` — small enough to read in one sitting. The composition is the lesson: choose the dotfolder name with `RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)`, serve `AgentSideConnection(stream: .stdio, logger: .standardError)`, then `connection.run()`. Add the executable target to Package.swift.
- **Show where a frontend appends its own tools.** The seam is `MultiTool.Builder.withCapability(_:)` before the build, for a capability behind the code-mode surface, and appending a plain `Tool` to the array `ToolCatalog.sessionTools(context:)` returns, for a stand-alone tool. The skills tool is the worked example of the second form. Do not describe the surface as a "pair": the session tools are `searchTools`, `runCode` and `wait`, plus `skills`.
- Must NOT grow argument parsing, rendering or config wizardry.
- Full-duplex shape. Never a read-request then write-response loop, which deadlocks on mid-turn updates (§20.2).

- Tier-3 gated test `Tests/FoundationModelsACPAgentTests/Integration/StdioContractTests.swift`, gated by an env var such as `ACP_TIER3=1`. Spawn the example as a subprocess. Drive initialize → session/new → a prompt whose turn runs a real shell command that writes to ITS stdout. Assert the protocol MUSTs of §17:
  - The agent's stdout carries only ndJSON frames. Child output must not leak, because the shell capability captures output and children do not inherit the agent's stdout.
  - No frame contains an interior newline.
  - Framing survives the process boundary, so every line parses as a JSON-RPC message.

**Reap the MCP servers on shutdown.** If the example composes any MCP server, add each `StdioServerProcess` to the `MCPServerPool` and call `shutdownAll()` after the session sweep. Every spawned pid also enters Extras' shared `ProcessRegistry.global`, which sweeps at exit, but the ordered shutdown is still ours to do.

- [ ] Example target compiles and serves stdio
- [ ] The frontend tool-append seam is shown, in both forms
- [ ] Gated subprocess test spawning the example
- [ ] stdout-purity and no-interior-newline assertions

## Acceptance Criteria
- [ ] `swift run acp-agent` starts and answers `initialize` over stdio, asserted by the gated test and not by hand
- [ ] With `ACP_TIER3=1` the contract test passes: every stdout line parses as JSON-RPC, and a subprocess `echo` during the turn never appears raw on the agent's stdout
- [ ] After the run, no child process remains
- [ ] Without the env var, `swift test` skips the suite and stays green

## Tests
- [ ] The gated suite above. Run `ACP_TIER3=1 swift test --filter StdioContract` → green locally
- [ ] Ungated `swift test` → green, with the suite skipped

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.