---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1gjqrt6ms5hya2ahf23njze
  text: |-
    Research done. Discoveries:

    - `SwiftUIACPClient.connect(over:logger:)` returns a `ClientSideConnection`. The connection has `initialize`, `newSession`, `prompt`, `updates(for:)` and `close()`.
    - The wire shapes: `InitializeRequest(info:protocolVersion:capabilities:)`, `NewSessionRequest(cwd: AbsolutePath)`, `PromptRequest(prompt: [.text(TextContent(text:))], sessionId:)`.
    - The answer text comes from `SessionUpdate.agentMessageChunk(ContentChunk)` with `case .text(let content) = chunk.content`. The turn end comes from `SessionUpdate.stateUpdate(.idle(IdleStateUpdate))` with the `stopReason`.
    - `StopReason` cases: `endTurn`, `maxTokens`, `maxTurnRequests`, `refusal`, `cancelled`, `unknown`. Only `endTurn` maps to exit 0.
    - `AgentProcess(command:arguments:)` requires an absolute path. It spawns with the parent's `environ`, so the test sets the environment on the outer `Process` and the inner `acp-agent` inherits it.
    - `ACPLogger.standardError` writes log lines to stderr. `acp-print` will pass it to `connect(over:logger:)`.
    - `BuiltProductLocator.executableURL(named:)` finds executables beside the test bundle. The test target must add a dependency on the `acp-print` target so `swift test` builds it there.
    - Plan for the agent path in `acp-print`: resolve `acp-agent` as a sibling of the `acp-print` binary (`Bundle.main.executableURL`). Both build into one products directory.
    - TDD order: write the gated `ClientServerTests` first, watch it fail (executable not found), then add the Package.swift target and `Examples/acp-print/main.swift`.
  timestamp: 2026-09-02T08:11:01.318872+00:00
- actor: claude-code
  id: 01m1gk4j887wrnmrske6snkwm4
  text: |-
    Implementation landed with TDD.

    RED: wrote `Tests/FoundationModelsACPAgentTests/Integration/ClientServerTests.swift` first. The gated run failed with "Could not find the acp-print executable" for all 3 tests. This is the correct failure.

    GREEN: added the `acp-print` product and target to `Package.swift` (links only `FoundationModelsACPClient` and `FoundationModelsACP`), wrote `Examples/acp-print/main.swift`, and added the test-target dependency so `swift test` builds the binary beside the test bundle. The gated run then passed: 3 of 3 tests.

    REFACTOR: extracted `Tests/.../Support/TierThreeFixture.swift` — the shared tier-3 gate, the agent executable name, the config-home variable, and the small-model `config.yaml` writer. `StdioContractTests` now uses the shared fixture, so the two tier-3 suites hold one copy of that setup. The gated `StdioContractTests` run stayed green after the refactor.

    Design notes:
    - `acp-print` finds `acp-agent` beside its own binary (`Bundle.main.executableURL`); both build into one products directory.
    - The turn flow: initialize → session/new(cwd) → subscribe updates → session/prompt → stream `agent_message_chunk` text to stdout → read the stop reason from the idle state update. The stop reason and all logs go to stderr. Exit 0 only for `end_turn`.
    - The failure test forces a fast agent death with a `config.yaml` that does not parse, so it does not need a model or the network.
    - The reap check uses `pgrep -f <built acp-agent path>` and expects no match.
    - The live turn gave a real non-empty answer this run; the known ^pez780d empty-answer defect did not show.

    Gated evidence: `ACP_TIER3=1 swift test --filter ClientServerTests` → 3 passed, 0 failed (live turn 7.5 s, models cached). `ACP_TIER3=1 swift test --filter StdioContractTests` → 1 passed, 0 failed.

    ### implement — changed
    - evidence: 5 files — Package.swift, Examples/acp-print/main.swift, Tests/FoundationModelsACPAgentTests/Integration/ClientServerTests.swift, Tests/FoundationModelsACPAgentTests/Support/TierThreeFixture.swift, Tests/FoundationModelsACPAgentTests/Integration/StdioContractTests.swift
    - next: run the full ungated test suite
  timestamp: 2026-09-02T08:18:00.584794+00:00
- actor: claude-code
  id: 01m1gk62td8tb9jf4g65gbh968
  text: |-
    ### test — green
    - evidence: `swift test` — 296 passed, 0 failed, 0 skipped in 34 suites (1 known issue: the pre-existing deliberate meta-test in HarnessSmokeTests). Gated suites stay disabled without `ACP_TIER3`. `ACP_TIER3=1 swift test --filter ClientServerTests` — 3 passed, 0 failed. `ACP_TIER3=1 swift test --filter StdioContractTests` — 1 passed, 0 failed. `swift build --build-tests` shows zero new warnings; the one "missing creator for mutated node" line for the mlx-swift Cmlx bundle is pre-existing build-system output.
    - next: commit
  timestamp: 2026-09-02T08:18:50.317166+00:00
- actor: claude-code
  id: 01m1gk6kafffkwq0svr7xsj51a
  text: |-
    ### commit — changed
    - evidence: 37a8ee2 feat(examples): add acp-print, the one-shot client-server prompt CLI (7 files, 542 insertions, 58 deletions)
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-02T08:19:07.215734+00:00
- actor: claude-code
  id: 01m1gkds62xp6gfb241qcm6027
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 2 refuted; 5 files reviewed, .kanban excluded by .reviewignore
    - next: task moved to done
  timestamp: 2026-09-02T08:23:02.594128+00:00
- actor: claude-code
  id: 01m1gke1x8jytfnrtrp84zc8re
  text: |-
    ### finish iteration 1 — done
    - implement: changed — 5 source files (Package.swift, Examples/acp-print/main.swift, ClientServerTests.swift, TierThreeFixture.swift, StdioContractTests.swift); TDD: RED (executable not found) then GREEN
    - test: green — `swift test` 296 passed, 0 failed, 0 skipped; `ACP_TIER3=1 swift test --filter ClientServerTests` 3 passed; `ACP_TIER3=1 swift test --filter StdioContractTests` 1 passed; zero new warnings
    - commit: changed — 37a8ee2 feat(examples): add acp-print, the one-shot client-server prompt CLI
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 2 refuted
    - outcome: the task is done in one iteration
  timestamp: 2026-09-02T08:23:11.528411+00:00
depends_on:
- 01KYSVEYTDHNBFA6B0XX36HV94
position_column: done
position_ordinal: '9880'
title: 'Examples/acp-print: one-shot client-server prompt CLI'
---
## What
Plan.md §20.2 (`acp-print`). A one-shot prompt CLI in the shape of `claude --print`: send one prompt, run the turn to completion, print the answer, exit. `FoundationModelsACPClient` (the Client role) drives `Examples/acp-agent` across a real process boundary — the client-server interop example for the two role packages.

**The upstream gate is CLEARED.** `FoundationModelsACPClient` shipped; its board shows M0–M7 done. Use `AgentProcess(command:arguments:)` to spawn `acp-agent` (absolute path; own process group; group-kill and reap on `shutdown()` and on transport teardown), `SwiftUIACPClient.connect(over: agent.transport)` for the connection, and `client.session(for:)` for the streamed `entries`. Do not hand-roll a second client here. This task still waits on `acp-agent`, because it spawns it.

- `Examples/acp-print/main.swift` — one positional prompt argument, nothing else (the no-second-product rule of `acp-agent` applies: no flag surface, no rendering options, no config wizardry). Add the executable target to Package.swift.
- The target links only `FoundationModelsACPClient` and the wire — never this package's library. Every byte crosses ACP; a back-door import would break the interop proof.
- The client spawns `acp-agent` over stdio and owns the process (process group + reap on shutdown, per the client plan's "Transports").
- Flow: initialize → session/new(cwd) → session/prompt → stream the `agent_message_chunk` text to stdout → exit at the stop reason.
- stdout carries only the answer text. Logs and the stop reason go to stderr. Exit code 0 for `end_turn`; nonzero for `refusal`, `cancelled`, or an error.
- Gated end-to-end test `Tests/FoundationModelsACPAgentTests/Integration/ClientServerTests.swift` (`ACP_TIER3=1`, the same gate as tier 3): run `acp-print` as a subprocess with a trivial prompt.

- [ ] Executable target `acp-print` with one positional prompt argument
- [ ] Links only the client package and the wire
- [ ] Spawn + own the `acp-agent` subprocess through the client transport
- [ ] stdout = answer text only; logs + stop reason on stderr; exit-code mapping
- [ ] Gated `ClientServerTests` suite

## Acceptance Criteria
- [ ] `swift run acp-print "say hello"` prints the answer text and exits 0 (asserted by the gated test, not manually)
- [ ] With `ACP_TIER3=1`: exit code 0, stdout contains only the answer text, stderr carries the logs
- [ ] After the run, no `acp-agent` process remains (the client reaped it)
- [ ] A refused or failed turn exits nonzero with the reason on stderr
- [ ] Without the env var, `swift test` skips the suite (still green)

## Tests
- [ ] The gated suite above; run `ACP_TIER3=1 swift test --filter ClientServer` → green locally
- [ ] Ungated `swift test` → green (suite skipped)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.