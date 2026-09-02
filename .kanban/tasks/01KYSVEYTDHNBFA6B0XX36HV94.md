---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gbtescsswr6sv4arzgyrmp
  text: |-
    Research findings before implementation:

    1. Shipped APIs the card's sketch predates:
    - `RoutedACPAgent.init(name:router:configuration:reporting:userDirectory:environment:)` is the real initializer. It is `async throws` and resolves `configuration.profile` at construction.
    - `AgentSideConnection` has no `run()`. The wire package's own `acp-test-agent` holds the process open with a sleep loop after `AgentSideConnection(stream: .stdio, logger: .standardError)`. The parent group-kills and reaps through `AgentProcess`.
    - `ToolCatalog.sessionTools(context:)` does not exist. The real door is `ToolCatalog.sessionSurface(context:)`, which returns a `SessionSurface` whose `tools` array gets the plain `skills` tool appended. The two seams are in `ToolCatalog`: `MultiTool.Builder` `with...()` calls before `buildRegistry()`, and the append to the tools array.

    2. Real model path: `Router(loader: LiveModelLoader(downloader: #hubDownloader(), tokenizerLoader: #huggingFaceTokenizerLoader()))` — the same shape as Router's own examples and Multitool's CLI. The macros need the `MLXHuggingFace` module (mlx-swift-lm, `stable` branch), plus `HuggingFace` (swift-huggingface, from 0.9.0) and `Tokenizers` (swift-transformers, from 1.3.0). All three are already in `Package.resolved` transitively; the manifest must declare them for the example target. The URL forms must match Router's exactly to avoid identity conflicts: `https://github.com/swissarmyhammer/mlx-swift-lm` and `https://github.com/huggingface/...`.

    3. The deterministic shell child for the gated turn: a project-layer skill whose body carries a shell injection (`!` plus a backtick command). `CommandDispatch` routes the skill through `registry.call`, whose render passes run the command as a real subprocess with captured output, before the rendered text feeds the model turn. This gives a real child that writes to its own stdout during the turn, with no dependence on the model's tool choice. The default `RenderPolicy()` keeps shell injection enabled.

    4. Gated model choice: the test writes a user-layer `config.yaml` (through `XDG_CONFIG_HOME`, which the spawned child inherits) with `mlx-community/SmolLM-135M-Instruct-4bit` for both chat slots and `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` for embedding — the small refs Router's examples and Multitool's gated suite proved with `LiveModelLoader`.

    5. Spawn path: the test target gains a dependency on the new `acp-agent` executable product, so `swift test` builds it beside the test bundle. The locator generalizes `MCPTestServerLocator` to find it. `AgentProcess(command:)` requires the absolute path; the tap wraps `agent.transport` (protocol `ACPTransport`: `bytes` stream plus `write`). Turn completion is observed through `connection.updates(for:)` — subscribe before the prompt.

    6. MCP servers: the default configuration composes no MCP server, so the example adds no pool handling of its own; `RoutedACPAgent` owns each session's `MCPServerPool` and `ProcessRegistry.global` sweeps at exit.
  timestamp: 2026-09-02T06:10:09.324251+00:00
- actor: claude-code
  id: 01m1gcgxk0fg363ecdbr8h8jtj
  text: |-
    Implementation decisions, recorded for the reviewer:

    1. TDD order held: the gated test landed first and failed with "Could not find the acp-agent executable at .build/out/Products/Debug/acp-agent". Then the manifest and the example landed, and the same test passed.

    2. The example serves through `AgentSideConnection(stream: .stdio, logger: .standardError)` and then holds the process open with a keep-alive loop, the shape of the wire package's own `acp-test-agent`. `AgentSideConnection` ships no `run()`; the client owns the lifecycle and group-kills the child (plan.md §17).

    3. The tool-append seam is shown as a pointed comment block in `main.swift`, in both forms: `builder.withCapability(_:)` in `ToolCatalog.makeRegistry(context:)` before `buildRegistry()`, and the plain-`Tool` append in `ToolCatalog.sessionSurface(context:)` with `skills` as the worked example. `RoutedACPAgent` has no public tool-injection parameter, and `ToolCatalog`'s own banner says capabilities are added there and only there — so the example points at the real seam instead of inventing a second one.

    4. The gated turn gets its deterministic shell child from a project-layer skill whose body carries a shell injection: `registry.call` runs `echo ... | tee ...` through `/bin/sh -c` with captured output during the `/probe` dispatch, before the rendered text feeds the real model turn. The on-disk `tee` witness proves the child ran (check the filesystem, never the transcript); the tapped raw bytes prove the marker never leaked outside a JSON frame.

    5. The gated test injects `XDG_CONFIG_HOME` so the spawned example's user config layer names the small proven models (`SmolLM-135M-Instruct-4bit` both chat slots, `Qwen3-Embedding-0.6B-4bit-DWQ` embedding). The resolution path stays fully real: `LiveModelLoader` with the hub macros, real download, real MLX load.

    6. `MCPTestServerLocator` became `BuiltProductLocator` with `executableURL(named:)`, so one locator finds `mcp-test-server` and `acp-agent` beside the test bundle. All four call sites updated.

    7. Results: RED run failed as expected; `ACP_TIER3=1 swift test --filter StdioContract` → 1 test passed in 85.8 s (first run, model download included); ungated `swift test` → 277 tests, 29 suites, all passed, the tier-3 suite skipped with its gate message; `pgrep -lf acp-agent` finds no leftover process. The "1 known issue" in the full run is the pre-existing `withKnownIssue` self-test in `HarnessSmokeTests`.
  timestamp: 2026-09-02T06:22:25.376666+00:00
- actor: claude-code
  id: 01m1gch45hff9dxvdkzesrnz4t
  text: |-
    ### implement — changed
    - evidence: 5 files — Examples/acp-agent/main.swift (new), Package.swift, Tests/FoundationModelsACPAgentTests/Integration/StdioContractTests.swift (new), Tests/FoundationModelsACPAgentTests/BuiltProductLocator.swift (renamed from MCPTestServerLocator.swift, generalized), call-site updates in TierTwoTests.swift and MCPCompositionTests.swift
    - next: test, commit, review
  timestamp: 2026-09-02T06:22:32.113123+00:00
- actor: claude-code
  id: 01m1gcwg8zw1b2ypgqfzcx27vx
  text: |-
    ### review — findings
    - evidence: 1 finding — Examples/acp-agent/main.swift:112 (swift/fluent-usage: label the first parameter of holdOpenUntilTerminated)
    - next: implement works the finding, then test, commit, and review again
  timestamp: 2026-09-02T06:28:44.959703+00:00
- actor: claude-code
  id: 01m1gcwnwdyy08zzr4za14sxgj
  text: |-
    ### finish iteration 1 — findings
    - implement: changed (Examples/acp-agent/main.swift, Package.swift, StdioContractTests.swift, BuiltProductLocator.swift rename, 2 call-site files)
    - test: green (277 passed, 0 failed; gated StdioContract passed with ACP_TIER3=1 in 85.8 s; tier-3 suite skipped ungated)
    - commit: ef26270
    - review: findings (1 — Examples/acp-agent/main.swift:112 swift/fluent-usage)
  timestamp: 2026-09-02T06:28:50.701487+00:00
depends_on:
- 01KYSVEH19FKV250W4KQG1RFCT
- 01KYSVCAH5MAEMCH4R5A8MNCSF
position_column: review
position_ordinal: '8180'
title: Examples/acp-agent and the gated tier-3 stdio contract test
---
## What
Plan.md §20.2 and §17. One executable, two purposes: the family-convention example AND the tier-3 fixture.

- `Examples/acp-agent/main.swift` — small enough to read in one sitting. The composition is the lesson: choose the dotfolder name with `RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)`, serve `AgentSideConnection(stream: .stdio, logger: .standardError)`, then `connection.run()`. Add the executable target to Package.swift.
- **Show where a frontend appends its own tools.** The seam is `MultiTool.Builder.withCapability(_:)` before the build, for a capability behind the code-mode surface, and appending a plain `Tool` to the array `ToolCatalog.sessionTools(context:)` returns, for a stand-alone tool. The skills tool is the worked example of the second form. Do not describe the surface as a "pair": the session tools are `searchTools`, `runCode` and `wait`, plus `skills`.
- Must NOT grow argument parsing, rendering or config wizardry.
- Full-duplex shape. Never a read-request then write-response loop, which deadlocks on mid-turn updates (§20.2).

- Tier-3 gated test `Tests/FoundationModelsACPAgentTests/Integration/StdioContractTests.swift`, gated by an env var such as `ACP_TIER3=1`. **Spawn the example through `AgentProcess(command:arguments:)` from `FoundationModelsACPClient`** (plan.md §20.1), with the absolute path of the built `acp-agent`. It spawns in its own process group and vends `transport`. Wrap `agent.transport` in a tap that records the raw inbound bytes, then `client.connect(over: tap)`. Drive initialize → session/new → a prompt whose turn runs a real shell command that writes to ITS stdout. Assert the protocol MUSTs of §17 on the tapped bytes, and assert teardown with `processIdentifier == nil` after `shutdown()`:
  - The agent's stdout carries only ndJSON frames. Child output must not leak, because the shell capability captures output and children do not inherit the agent's stdout.
  - No frame contains an interior newline.
  - Framing survives the process boundary, so every line parses as a JSON-RPC message.

**Reap the MCP servers on shutdown.** If the example composes any MCP server, add each `StdioServerProcess` to the `MCPServerPool` and call `shutdownAll()` after the session sweep. Every spawned pid also enters Extras' shared `ProcessRegistry.global`, which sweeps at exit, but the ordered shutdown is still ours to do.

- [x] Example target compiles and serves stdio
- [x] The frontend tool-append seam is shown, in both forms (see the note: the shipped seams are `builder.withCapability(_:)` in `ToolCatalog.makeRegistry(context:)` and the `tools` append in `ToolCatalog.sessionSurface(context:)` — `sessionTools(context:)` on this card predates the shipped API)
- [x] Gated subprocess test spawning the example
- [x] stdout-purity and no-interior-newline assertions

## Acceptance Criteria
- [x] `swift run acp-agent` starts and answers `initialize` over stdio, asserted by the gated test and not by hand
- [x] With `ACP_TIER3=1` the contract test passes: every stdout line parses as JSON-RPC, and a subprocess `echo` during the turn never appears raw on the agent's stdout
- [x] After the run, no child process remains
- [x] Without the env var, `swift test` skips the suite and stays green

## Tests
- [x] The gated suite above. Run `ACP_TIER3=1 swift test --filter StdioContract` → green locally
- [x] Ungated `swift test` → green, with the suite skipped

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-02 01:23)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsACPAgentTests/MCPTestServerLocator.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsACPAgentTests/MCPTestServerLocator.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsACPAgentTests/MCPTestServerLocator.swift, so its declarations are unread

- [ ] `Examples/acp-agent/main.swift:112` `swift/fluent-usage` — First parameter of a non-conversion function should be labeled. The fluent-usage rule requires: 'Omit the first argument label only for value-preserving conversions. Otherwise, label it.' This function does not perform a type conversion, so the unlabeled parameter violates the rule. Change to `func holdOpenUntilTerminated(connection: AgentSideConnection) async {`. Update the call site at line 118 to `await holdOpenUntilTerminated(connection: connection)`.