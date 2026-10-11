---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
title: Give the host the tool records of an agent run, so the run-call join table gets exact entries
---
## Problem

Task ^9xk3xf4 makes `RunCallJoinTable` decide the wire id of each shell run from events only. A shell run of an agent run (the `agents` tool) uses the shell capability of the root session, so its output comes on the root `ShellOutputChunkStream`. But its `toolInvocation` records go to the event stream of the agent run, and FoundationModelsAgents reads that stream in a private loop (`AgentRun.follow` in `Run/AgentRun+Drive.swift`). `AgentEnvironment` and `AgentRunner` take no event observer. Thus this package cannot write an exact entry for such a run.

The fallback of ^9xk3xf4: the end of an agent run (the close record or the settlement of an `agents` run in the root projection) writes "no join" for each waiting run, and the end of the root prompt does the same.

## Known limit of the fallback

A root shell run that starts just after an agent run ended, and whose first chunk comes before the root projection handled its open record, also gets "no join" from the agent-end write. Then its terminal announce and its run updates go on the completion token, while the SDK `toolCall` and `toolStatus` events go on the SDK id: two tool calls for one run. The window is the lag of the root projection.

## What to change

- FoundationModelsAgents: give the host an observer of the session events of each agent run (for example, an `AgentEnvironment` parameter that receives each `SessionEvent` of a run, or only its `toolInvocation` records), or another public way to read the completion tokens of the tool runs of a run.
- FoundationModelsACPAgent: write "no join" into the `RunCallJoinTable` of the session for each open record of an agent run, before the shell body starts. Then remove the agent-end write (`RunCallJoinTable.runDidEnd(tool:)`).

## Acceptance

- [ ] A shell run of an agent run gets its entry from its own open record, not from the end of the agent run.
- [ ] A root shell run that starts after an agent run ended keeps its SDK id (a test with the root chunk before the root open record and after the agent-end event).
- [ ] The agent-end write is gone.