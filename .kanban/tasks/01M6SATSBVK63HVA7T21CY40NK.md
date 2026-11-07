---
assignees:
- claude-code
position_column: done
position_ordinal: ffffc280
title: Remove the inbound gate of acp-agent after the FoundationModelsACP fix of the early-initialize race
---
BLOCKED: do no code until the peer session sends the FoundationModelsACP commit.

Background: `InboundEndTransport(wrapping:holdingInbound:)` holds stdin until the agent role is set. It is a workaround for a race in `AgentSideConnection`: a frame in the pipe is served before `setRole`, and the request fails with `methodNotFound`. The root fix is in FoundationModelsACP (session foundationmodelsacp-32).

When the commit arrives:
- [ ] Move the pin to the commit of FoundationModelsACP (run `swift package update`).
- [ ] Remove the gate: the `holdingInbound` parameter, the gate stream, and `releaseInbound()` in `Sources/acp-agent/InboundEndTransport.swift`.
- [ ] Remove the `releaseInbound()` call and `holdingInbound: true` in `Sources/acp-agent/AcpCommand.swift`.
- [ ] Replace test `aHeldTransportForwardsNothingBeforeTheRelease` with a test that writes `initialize` before the agent is ready and gets no `methodNotFound`, with the gate gone.
- [ ] Run the unit tests once. Do not run integration tests. Do not push without the words of the user.