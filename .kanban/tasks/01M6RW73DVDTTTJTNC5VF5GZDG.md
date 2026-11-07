---
assignees:
- claude-code
position_column: done
position_ordinal: ffffbe80
title: Make the start-up of `acp-agent acp` serve an early initialize
---
Flake seen in FoundationModelsACPClient: `aKanbanMutationGivesOneSubscriptionEvent` failed once because the agent answered `initialize` with methodNotFound. The same fault failed `StdioContractTests.framingSurvivesTheProcessBoundaryWhileAShellChildRuns` in CI run 42215415795.

Cause (read in the code): `AgentSideConnection.init` starts the read loop inside `Connection.init`, and sets the role after the factory built the agent (`RoleConnectionCore.setRole`). A frame that is in the pipe before that point meets no role, so the reply is methodNotFound.

Fix in this repo: commit 51332f3. `InboundEndTransport(holdingInbound: true)` holds the input; `acp` mode calls `releaseInbound()` after `serve` returns. Unit test `aHeldTransportForwardsNothingBeforeTheRelease` fails with the gate open.

Open: check that CI run 42252343842 is green. The root fix belongs in FoundationModelsACP (the connection should hold requests until the role is set). Any other host that serves over a transport with data already waiting has the same race (the graphql-tunnel-server of FoundationModelsACPClient/IntegrationTests/LiveAgentServer: check that it also uses a gate or the fixed library).