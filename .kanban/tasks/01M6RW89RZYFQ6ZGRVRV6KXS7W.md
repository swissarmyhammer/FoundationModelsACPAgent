---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6v7828rngepx80gas42kjtp
  text: |-
    ### Done by FoundationModelsACP b6b265c
    The read loop of each role connection waits on an InboundGate until RoleConnectionCore.setRole. Thus a frame in the pipe before the role finds the role.
    Tests (deterministic): readLoopWaitsForTheRoleBeforeItReadsAFrame and closeBeforeTheRoleEndsTheConnectionWithNoResponse.
    Differences from this card: the fix is a gate in the read loop, not an async wait in RoleHolder. A close before setRole sends nothing (the card asked for methodNotFound). The tests use a hook of the gate, because the factory is synchronous.
    ACPAgent uses it in f1a5604 (gate removed, early-initialize test added). CI run 42382069489 is green.
  timestamp: 2026-11-07T14:40:20.248010+00:00
position_column: done
position_ordinal: ffffc180
title: 'FoundationModelsACP: hold requests until the role is set (root fix of the early-initialize race)'
---
Repository: FoundationModelsACP (no session works there now). This card is for the person to carry over.

Fault: `Connection.init` starts the read loop (`readTask = Task { await self.readLoop() }`, Connection.swift:621). `AgentSideConnection.init` sets the role only after the factory built the agent (`core.setRole`, AgentSideConnection.swift, after `factory(self)`). `RoleConnectionCore.routeRequest` throws `RequestError.methodNotFound` when `holder.servedRole` is nil. A frame that is in the pipe before `setRole` gets methodNotFound. The doc of `setRole` says "called once before the read loop dispatches", and that is not true. `ClientSideConnection` has the same shape.

Seen: CI of FoundationModelsACPAgent, run 42215415795, `StdioContractTests` (`initialize` answered methodNotFound); FoundationModelsACPClient integration run, `aKanbanMutationGivesOneSubscriptionEvent`.

Change: `RoleHolder` gets an async wait. `routeRequest` and `routeNotification` await the served role (not throw) when the role is not set yet. Release the waiters in `set`. Give the wait a way out when the connection closes before the role is set (reply with methodNotFound then, or drop the notification). Keep the order of the requests.

Test (no clock): a transport that has an `initialize` frame ready before the connection is built, and a factory that suspends until the test lets it go. The reply must be the `initialize` result, never methodNotFound.

Work-around in ACPAgent: commit 51332f3 (`InboundEndTransport(holdingInbound:)`). It can stay; it does no harm after the root fix.