---
depends_on:
- 01KY7EEGS0JJ5G6720FGSEBT3M
position_column: todo
position_ordinal: 8f80
title: 'Examples/acp-agent: an ACP server CLI streaming over stdio'
---
## What

Plan **§10.2** — `Examples/acp-agent`, a runnable example showing how to build an agent CLI that is an ACP server, streaming ACP over stdio. Filed 2026-07-29.

**One executable serves two purposes deliberately**: it is the example a reader learns from, *and* the binary the tier-3 gated stdio test spawns (`yxj21nw`). Writing it twice would guarantee the example rots while the fixture stays green. The family convention is an `Examples/` directory of runnable programs — Router and MCP both ship one.

## The composition is the lesson

Keep it small enough to read in one sitting:

```swift
// the dotfolder name is the frontend's choice (§4) — everything else derives from it
let agent = try await RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)

// serve ACP over stdio; stdout is sacred, logs go to stderr
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in agent }
await connection.run()
```

Must demonstrate, because these are the questions a reader actually has:
- choosing the dotfolder `name` and what it controls (config stack, transcripts root, profile fallback — §4);
- serving over `AgentSideConnection(stream: .stdio)`;
- **logging to stderr only**;
- where a frontend adds its own tools to the merged roster (§7.1).

Must **not** become a second product: no argument parsing beyond what stdio serving needs, no rendering, no config wizardry. The production CLI grows in its own repo from a copy of this (§9).

## Streaming — the part that is easy to get wrong

ACP over stdio is **full duplex, not request/response**, and v2 makes that unavoidable: `session/prompt` returns `{}` immediately and the whole turn — `user_message`, `running`, every `agent_message_chunk` and `tool_call_update`, then `idle` — arrives afterwards as notifications **on the same pipe the connection is still reading requests from**. An example written as a read-request / write-response loop deadlocks the moment it emits an update mid-turn, so the shape matters pedagogically as much as functionally.

Three things the wire package already handles — do not reinvent them:

- **Frame serialization.** `StdioTransport`'s write "runs under a lock, so overlapping calls from the connection actor's reentrant methods serialize into non-interleaved frames." Concurrent sessions cannot produce a torn line.
- **Respond-then-notify ordering.** `AgentSideConnection.afterRespondingToCurrentRequest(_:)` defers work until after the `{}` has gone out — that is how §9.1's "respond first, then emit `user_message`" is achieved. Use it rather than a detached task that races the response.
- **Lifecycle.** The client launches the agent as a subprocess and terminates it; the agent reads until stdin EOF. No teardown handshake to implement.

## The hazard to defend against

**Subprocess stdout.** `shell` spawns children, and a child that *inherits* the agent's stdout writes straight into the ACP frame stream — corrupting it silently, in a way no unit test catches because the tool itself behaved correctly. Shelltool captures rather than inherits (§7.1); this example must not undo that by wiring inherited handles anywhere.

"The agent MUST NOT write non-ACP content to stdout" is a protocol MUST (§Transports), not a house rule.

## Acceptance Criteria

- [ ] `Examples/acp-agent` builds as an executable target and runs, serving ACP over stdio.
- [ ] A real client can complete `initialize` → `session/new` → `session/prompt` against it.
- [ ] All logging goes to stderr; stdout carries only ndJSON frames.
- [ ] Notifications stream during a turn rather than being batched at the end.
- [ ] The file stays short enough to read in one sitting; composition is legible, not buried in scaffolding.
- [ ] It is the same binary `yxj21nw` spawns — not a parallel implementation.

## Tests

- [ ] Spawn the example, drive a full handshake and one turn, assert **every stdout byte parses as ndJSON**.
- [ ] Run a turn whose tool call is a `shell` command that writes to its own stdout; assert the agent's stdout is still pure.
- [ ] Assert no emitted frame contains an embedded newline (protocol MUST).
- [ ] Assert `session/prompt`'s `{}` response is observed **before** the first `user_message` notification.
- [ ] Close stdin; assert the process exits cleanly without orphaned children.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.