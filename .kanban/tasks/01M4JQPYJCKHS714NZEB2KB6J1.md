---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: Give the agent environment to the CatalogContext of each session composition
---
## Problem

`RoutedACPAgent.composeSession(from:workingDirectory:additionalRoots:clientMCPServers:)` (`Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`) makes its `CatalogContext` with no `environment:` argument. Thus `CatalogContext.environment` is `ProcessInfo.processInfo.environment`, not `RoutedACPAgent.environment`. The web capability reads its API keys from `CatalogContext.environment` (task ^ba231ka). A host or a test that gives the agent an environment does not reach the web capability.

Found during task ^c4a6mwy (2026-10-10). Not changed there, because it is outside that task.

## What to change

- Decide if the session composition must give `environment: environment` to `CatalogContext`. Check the callers that depend on the process environment (bench, `ComposedAgent`, the stub agent with `StubAgentDefaultsLayer.makeEnvironment`).
- Add a test that fails when the agent environment does not reach `CatalogContext.environment`.

## Acceptance

- [ ] The decision is recorded, and a test proves the chosen behavior.