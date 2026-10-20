---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5d1xef8k71tyb38r9e83hhh
  text: |-
    EXTRAS-2, -5, -6 and -7 (the GraphQL toolkit) are pushed: FoundationModelsExtras main 03ceab849a7b3eaa851d2859161eddde9778dfa7 (from the Extras session, 2026-10-20). Update the Extras dependency to this sha or later.
    - Endpoint: conform a type to `GraphQLEndpoint` (name, version, scope `.server`, schema SDL, `execute`/`subscribe` with `viewer: GraphQLViewer?`).
    - Schema: build it with Graphiti and `SchemaBuilder.addToolkitScalars()`. Run it with `API.respond(to:variables:operationName:rules:formattedWith:context:)`; the context conforms to `GraphQLRunContext`. Give the aliases as `GraphQLNameRules`.
    - Tool: `GraphQLTool(description:endpoint:)`, or an own Tool that conforms to `GraphQLEndpointTool` and calls `GraphQLTool.answer(...)`. The tool must also conform to `OperationDescribing` for Multitool (card ^e7qftfw).
    - Test kit: `GraphQLEndpointConformance.problems(of:scope:probe:)`, `GraphQLSchemaDescriptions.undescribed(in:)`, `GraphQLSchemaGolden.problems(of:against:)`. Use them in the tests of this card.
    - Worked example: FoundationModelsExtras `Tests/FoundationModelsExtrasTests/GraphQL/ExampleGraph.swift`.
  timestamp: 2026-10-20T16:22:05.544059+00:00
- actor: wballard
  id: 01m5dckhmkwc0vhyzm0kmyxxze
  text: 'Note from ^3ytw5vx (2026-10-20): `SettingsStore.stopWatching()` stops each watcher, removes each level from memory and ENDS each `changes()` stream. `closeOpenSessions(after:)` calls it when a connection closes. If one agent serves more than one connection (the tunnel, D54), the subscription of a second client must not end when the first client leaves. Check this in this card: either stop the watch only when the last connection closes, or let a subscription start a new `changes()` stream after a stop. Add a test with two connections.'
  timestamp: 2026-10-20T19:28:55.443262+00:00
- actor: claude-code
  id: 01m5dg6rkratxj7chbw1vnyvpg
  text: |-
    Research (implement step):
    - Extras 018f9ab has the GraphQL toolkit. Extras does not re-export GraphQL or Graphiti. This package must declare both packages itself with the floors of Extras (GraphQL 4.3.0, Graphiti 3.1.0), the same as FoundationModelsKanban does. Same URLs, thus one package identity.
    - The Extras example graph has no subscription. The Kanban `changes` subscription is the prior art: `SubscriptionField(name, as: T.self, atSub: Resolver.method)` that gives an AsyncSequence.
    - The conformance check needs an alias probe, thus the name rules of the endpoint must have one alias at least.
    - A key path of `SettingsStore` goes through mappings only. The MCP servers are a list under `tools.mcp`, thus a change of an MCP server sets the full list. The secret check must walk the full value that a change writes.
    - Secret keys in the schema: `tools.web.apiKeys.<name>` and `tools.mcp[].headers.<name>`. An `env` value of an MCP server is not always a secret (the codec shows a literal env value as it is), thus a literal env value stays allowed.
    - `RoutedACPAgent.closeOpenSessions(after:)` calls `settingsStore.stopWatching()`, which ends each `changes()` stream. Plan: the engine subscription starts a new `changes()` stream after a stop, reads its levels again (so that the watchers start again), and sends one change with no key path for each level, because a change can come between the stop and the new read.
    - `SettingsTool`: model arguments are a GraphQL document (`GraphQLArguments`, through `GraphQLTool.answer`). For Multitool it gives one operation, `query settings` (verb `querySettings`), whose payload is the same document.
  timestamp: 2026-10-20T20:31:50.904041+00:00
- actor: claude-code
  id: 01m5dhazw645anfjn3zrsfngcn
  text: |-
    Implementation landed (not committed):
    - Package.swift: the library and the unit test target link GraphQL (4.3.0), Graphiti (3.1.0) and OrderedCollections (swift-collections 1.0.0), with the URLs and floors of Extras. Package.resolved did not change.
    - New folder Sources/FoundationModelsACPAgent/Settings/: SettingsEngine (the one engine over SettingsStore), SettingsSecretKeys (secret keys `tools.web.apiKeys.*` and `tools.mcp[].headers.*`; redaction of a literal; refusal of a literal), SettingsGraphError (CodedError codes UNKNOWN_SECTION, INVALID_KEY_PATH, INVALID_CWD, SECRET_NEEDS_REFERENCE, TEMPLATE_NOT_KEPT, INVALID_VALUE, NO_LEVEL, SECRET_UNREADABLE), SettingsGraphSchema (Graphiti API), SettingsGraph (endpoint `settings`, scope server), SettingsTool (GraphQLEndpointTool + OperationDescribing, op `query settings`, verb `querySettings`).
    - Schema: `Query.sections`, `Query.setting(keyPath, cwd)`, `Mutation.set(keyPath, value, level, cwd)`, `Mutation.clear(keyPath, level, cwd)`, `Subscription.changes(cwd)`. Aliases: `key` for `keyPath`, `setSetting`/`update` for `set`, `clearSetting`/`unset`/`remove` for `clear`. Golden file: Tests/Fixtures/settings.graphql.
    - Two connections: SettingsStore gets `startWatching(cwd:)`. The engine subscription starts a new `changes()` stream when `stopWatching()` ends the old one, reads its levels again, and sends one change with no key path for each level (USER, then SESSION of cwd), because a change can come between the stop and the new read. Test: SettingsSubscriptionTests.aSubscriptionLivesOnWhenADifferentConnectionCloses.
    - Found and fixed: a standardized cwd URL drops `/private` from a temporary path, and the store then keeps a second copy of the same level under a different path. The engine keeps the cwd path as the call gives it.
    - For ^e7qftfw: make the tool with `SettingsTool(store: agent.settingsStore)` and mount it with `withOperationTool(noun: "settings", tool:)`.
  timestamp: 2026-10-20T20:51:37.990151+00:00
- actor: claude-code
  id: 01m5dhb3whn5yk0g27qygpyrmx
  text: |-
    ### implement — changed
    - evidence: `swift test` 1142 tests in 124 suites passed, 0 failures (1 known issue is the existing withKnownIssue of HarnessSmokeTests; the only warning is the existing SwiftPM "missing creator" of the mlx-swift bundle). New suites: SettingsGraphTests 17, SettingsSubscriptionTests 3, SettingsToolTests 7, SettingsStoreTests +1. Files: Package.swift; Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift; Sources/FoundationModelsACPAgent/Settings/{SettingsEngine,SettingsSecretKeys,SettingsGraphError,SettingsGraphSchema,SettingsGraph,SettingsTool}.swift; Tests/Fixtures/settings.graphql; Tests/FoundationModelsACPAgentTestSupport/SettingsFoldersFixture.swift; Tests/FoundationModelsACPAgentTests/{SettingsGraphTests,SettingsSubscriptionTests,SettingsToolTests,SettingsStoreTests}.swift; Tests/FoundationModelsACPAgentTests/Support/SettingsGraphFixture.swift
    - next: review
  timestamp: 2026-10-20T20:51:42.097739+00:00
- actor: claude-code
  id: 01m5dhfqewmw8vgxbb9pypn7gd
  text: |-
    ### test — green
    - evidence: `swift test` — 1142 tests in 124 suites passed, 1 known issue (the accepted withKnownIssue in HarnessSmokeTests), 0 failed, 0 skipped. `swift build --build-tests` after touching all changed Swift files — Build complete, 0 compiler warnings. `swift build --build-tests --package-path IntegrationTests` — Build complete, 0 compiler warnings. Three runs of SettingsGraphTests, SettingsSubscriptionTests, SettingsToolTests and SettingsStoreTests (the filter also matched SessionSettingsStoreTests) — 46 tests in 5 suites passed each time, no flake. Only warning in the output: the accepted SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle.
    - next: review
  timestamp: 2026-10-20T20:54:13.212235+00:00
depends_on:
- 01M5CZ35E8P2EZTW5GW3YTW5VX
- 01M5DCV6DGXMS6FGXQ6AEFMPDZ
position_column: doing
position_ordinal: '80'
title: 'ACPA-17: the settings GraphQL endpoint and SettingsTool over one engine'
---
## What
ACPA-17, D100 and D75: ACPAgent owns the configuration, so it gives the `settings` GraphQL endpoint and its own `SettingsTool` over the same engine, through `GraphQLEndpointTool` of FoundationModelsExtras.

**Blocked outside this board:** EXTRAS-6 (GraphQL toolkit) and EXTRAS-7 (`GraphQLEndpointTool` protocol) must be in FoundationModelsExtras first. Now there is no GraphQL code in this repository, in Extras or in Multitool. Do not change Extras from this board.

Do this after EXTRAS-6 and EXTRAS-7:
- A schema over `SettingsStore` (card ^3ytw5vx). Keys are the keys of `AgentConfiguration` (`AgentConfiguration.swift:32`, `sectionSchemas` line 99): the models (`profile`), the tools, the MCP servers and the other sections.
- Query: the merged value of a key for a session (cwd), and the level that set it (`user` or `session`).
- Mutations: `set(keyPath, value, level)` and `clear(keyPath, level)`. Each mutation names its level. `clear` on the session level makes the user value apply again.
- Subscription: each change of `SettingsStore.changes()`.
- Secrets: a secret key reads and writes only the `keychain:` reference, and the query tells if the Keychain has an item for it (a bool). No value goes through the endpoint or the tool. A mutation that gives a literal value for a secret key is refused with a message that asks for a `keychain:` reference.
- The device settings (the Sharing switch, the login item, the TCC grants) are not in the schema.
- `SettingsTool` conforms to `GraphQLEndpointTool` and uses the same engine. This card does not register it in a session; the next card does.

## Acceptance Criteria
- [ ] A query gives the merged value and its level.
- [ ] A `set` on each level and a `clear` on the session level work through the endpoint and through the tool.
- [ ] The subscription sends a change after a mutation and after an outside file change.
- [ ] A literal value for a secret key is refused; a reference is accepted; the query gives the reference and `hasValue`.

## Tests
- [ ] Engine tests with temporary folders and `InMemorySecretStore` for each criterion.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17