---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3zax8bf4bsthatphgrjknc9
  text: 'Upstream confirmed and carded (FoundationModelsACP, 2026-10-02). `Connection.shutDown()` already runs on end of input, transport error and explicit close, but `AgentSideConnection` does not expose it. Proposed: `public var closed: ConnectionCloseReason { get async }` with `.endOfInput`, `.transportFailed(any Error)`, `.closedLocally`, on both AgentSideConnection and ClientSideConnection; it fires exactly once for all three paths, every waiter (also a late one) gets the same reason, and only after every inbound handler task has ended. The final name can change. Not started; the owner decides when it runs. Blocked until that session sends the commit.'
  timestamp: 2026-10-02T22:14:12.591093+00:00
- actor: claude-code
  id: 01m3zbdxb4egjty4xy5z75qc87
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — blocked on the upstream FoundationModelsACP "connection closed" signal (proposed `closed: ConnectionCloseReason`); carded there, not started, the owner decides when it runs
    - next: when that session sends the commit and the final name, move the pin and run /implement on this card
  timestamp: 2026-10-02T22:23:18.372204+00:00
position_column: todo
position_ordinal: '8380'
title: A connection that drops without session/close leaves its sessions open, and a debug build stops on a Multitool assertion
---
## Problem

Found in ^hkr6ykz / ^w93shct (2026-10-02). The session history sink holds the agent and the connection weakly. When a client drops the connection with no `session/close`, the agent and its sessions go away without a close. A session that mounts an MCP server then releases its `SurfaceRefresher` while its watch task still runs, and Multitool's debug assertion stops the process (`SurfaceRefresher.swift:136`). The tests avoid it because `ScriptedPromptFixture.close()` now sends `session/close` for each session. A host in production can still drop the connection.

## Cause

FoundationModelsACP gives the agent no signal that its connection closed (end of stdin, transport error). Thus the agent cannot run its own close path for each open session.

## What to do

1. Ask the FoundationModelsACP session for a public "connection closed" signal on `AgentSideConnection` (for example an async `closed` property or an `onClose` callback that runs one time).
2. When it is pushed: on that signal, the agent runs its `session/close` path for each open session (finish the shell stream, shut down the MCP pool, write `session-history.json`), then releases the sessions.
3. Test: a scripted client that drops the wire with an MCP-mounted session open; the process does not stop, the history file is written, and the model pool is empty.
4. Separately, consider whether the Multitool assertion at `SurfaceRefresher.swift:136` must be a log line, not an assertion, because a release without a stop is possible. Ask the Multitool session if the evidence supports it. #upstream