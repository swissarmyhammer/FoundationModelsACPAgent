---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5faa9g2217vpq9z9akn7z66
  text: 'Check (research): the key fits. `HookLineage.replacement(in:)` in Agent/AgentHooks.swift gives `HookLineage(sessionKey: sessionId.rawValue, origin: .replacement)` — Router gives the ACP session id as the key of the first Router session, and a replacement continues it. SessionLifecycle.swift `session/delete` calls `removeSnapshotTimeline(sessionKey: params.sessionId.rawValue)`. So the default resolver of `SnapshotsCapability` (session id -> same string as key) is correct here, and ToolCatalog needs no custom resolver. Mount: `ToolCatalog.makeRegistry(context:)` does `if let snapshotStore = context.snapshotStore { builder.withCapability(SnapshotsCapability(store: snapshotStore)) }`, and `RoutedACPAgent.catalogContext(from:...)` (Agent/SessionSetup.swift) passes `snapshotStore: hooks.snapshotStore` and `settingsEndpoint: settingsEndpoint`; the settings tool mounts via `withOperationTool(noun: SettingsGraph.endpointName, tool:)`. Multitool checkout is c9f70cd (Package.resolved). `MultiTool` (runCode, a top-level tool from `makeSessionToolsAndStaging`) gives `holder.current.registry.graphQLEndpoints`. SnapshotsGraph: `endpointName = "snapshots"`, version "1", scope .server (instance lets; only the name is a static constant; same for SettingsGraph). Test plan: unit test in the main test target composing via `agent.composeSession(...)` on `AgentClientHarness.makeInitializedAgent` (IntegrationTests/ is the cross-process/live-model package, not for this).'
  timestamp: 2026-10-21T13:27:23.906288+00:00
position_column: doing
position_ordinal: '8380'
title: 'EXTRAS-9: a composed session gives the settings and snapshots endpoints through its top-level tools'
---
From the Multitool session (coordination card, a check that this repo owns).

FoundationModelsMultitool origin/main c9f70cd has two changes:
- 5199380 and 9b0e866: `MultiTool` (runCode) conforms to `GraphQLEndpointTool`. It gives the endpoints of each capability in its registry, and of each operation tool that is mounted with `withOperationTool` and conforms (SettingsTool). When a (name, scope) repeats, the first one is kept.
- 2a30e09: the `snapshots` endpoint (MT-13), from SnapshotsCapability. `SnapshotsCapability.init` gets an optional resolver from a session id to a session key. The default uses the session id as the key.

## Check
- The key fits: the snapshot session key here is the ACP session id raw value (`AgentHooks.swift:115` `HookLineage(sessionKey: sessionId.rawValue, …)`, `SessionLifecycle.swift:64`). So the default resolver is correct. Confirm that the registry mounts `snapshots` over `CatalogContext.snapshotStore` (`Tools/CatalogContext.swift:104`).

## Done when
- A failing test first (TDD), in an integration test that composes a session: the endpoints of the top-level tools (`graphQLEndpoints`) include `settings` (scope server) and `snapshots`, each with its name, version and scope.
- Do this after the Multitool update to c9f70cd or later. Do it in the same change as the Extras update (EXTRAS-11), which needs ^hfw2eqh or the rule exceptions in SettingsGraphTests.
- The full `swift test` passes. #extras-9