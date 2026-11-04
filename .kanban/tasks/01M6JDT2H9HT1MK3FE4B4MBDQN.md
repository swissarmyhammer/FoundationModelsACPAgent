---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Make a recording with an interrupted nested child for AgentViewKit (stub model, agentSpawn, no endedAt)
---
AgentViewKit needs a recording to test the resume of a nested session tree. The recording must come from the agent, not from hand-written Router records.

Needs: (1) a child Router record with agentSpawn, parentSessionId and parentToolCallId, with a chain to the root; (2) no endedAt mark: the process quits with the sessions suspended (card ^59111kq is done); (3) the first prompt of the child in its transcript; (4) a recording root that the agent knows; (5) an agent definition that exists in the current config. A grandchild is wanted for the check "a child that has a child".

Steps: use the stub model script (ACP_AGENT_STUB_SCRIPT) to run a root, a child and a grandchild; then quit the process with an orderly shutdown while the child still runs. Write the path and the steps in the README. Send the path and the steps to the session agentviewkit-20.

Depends on ^wd0cwz7 (cold resume), which is stuck on the Multitool blocker. #subagents