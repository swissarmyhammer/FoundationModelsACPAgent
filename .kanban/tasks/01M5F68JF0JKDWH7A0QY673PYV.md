---
assignees:
- claude-code
position_column: todo
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