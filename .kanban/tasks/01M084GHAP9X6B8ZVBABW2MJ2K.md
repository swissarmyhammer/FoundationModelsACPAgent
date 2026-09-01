---
assignees:
- claude-code
depends_on:
- 01KYSVEYTDHNBFA6B0XX36HV94
position_column: todo
position_ordinal: 9c80
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