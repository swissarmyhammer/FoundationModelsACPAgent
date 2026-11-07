---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6rw86055s435adrb4v0cvq9
  text: |-
    Direction accepted by the peer session, with changes. Do not build it before the Kanban step (step 4): a kanban mounted before then records each edit of a person as the agent.
    - Make no new table of graphs. Use `KanbanHost.shared.session(workingDirectory:actor:)` (FoundationModelsKanban, Tool/KanbanHost.swift:153). It shares one engine for each folder and gives one view for each actor. The Kanban package owns the release rules.
    - The seam makes TOOLS for each session, for example `sessionToolFactories: [(SessionContext) async throws -> [any Tool]]`, not only endpoints. The model gets KanbanTool too, so its writes go through the same graph with viewer nil (the agent actor). The tunnel finds the endpoint through the GraphQLEndpointTool of the session, as it does now.
    - The card stays open. The peer will say when Kanban is pushed.
  timestamp: 2026-11-06T16:49:40.869319+00:00
position_column: done
position_ordinal: ffffc380
title: 'Design: mount Kanban in the real agent (proposal only)'
---
Design only, no code. A client must reach the `kanban` endpoint of a session in the real agent. Today only the integration test server registers KanbanTool. ACPAgent does not depend on FoundationModelsKanban and Kanban does not depend on ACPAgent, so there is no cycle.

Decide: (a) where the mount goes (the ToolCatalog of the library, or the composition of the `acp-agent` executable); (b) how one KanbanGraph is made for each session folder, with the agent name as the session actor.

Send the proposal to swissarmyhammer-75. Do not write code until it is accepted.