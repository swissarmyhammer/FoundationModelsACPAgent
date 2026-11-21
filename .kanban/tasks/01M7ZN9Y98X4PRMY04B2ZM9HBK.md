---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A failed session surface leaves the skills registry, the marketplaces and the built surface parts running
---
Found on 2026-11-21 during ^22h3kvw.

## Facts

- `RoutedACPAgent.composeSession` (SessionSetup.swift) makes a watching skills source (`ToolCatalog.makeSkillsSource`, `watch: true`) and starts the skills marketplaces (`ToolCatalog.startSkillsMarketplaces`) before `ToolCatalog.sessionSurface`. When `resolveSessionAgent` or `sessionSurface` throws, ^22h3kvw stops the agent registry, but nothing stops the skills registry or the marketplaces.
- `ToolCatalog.sessionSurface` builds the registry (`makeRegistry`: MCP pool, shell and code-context leases) and the agents mount (`AgentsComposition.compose`). When a later step throws (`makeSessionsTool`, `makeMCPServersTool`), nothing shuts down the parts that it built.

## Work

- [ ] Stop the skills registry and the marketplaces on each error path of `composeSession` before the surface owns them.
- [ ] Shut down the built parts of `sessionSurface` when a later step of `sessionSurface` throws.

## Tests

- [ ] A test shows that each failed composition stops what it started. The `ReloadHold` pattern of ^22h3kvw (Tests/FoundationModelsACPAgentTests/Support) shows how to keep an object alive, so that only a stop ends its watch.