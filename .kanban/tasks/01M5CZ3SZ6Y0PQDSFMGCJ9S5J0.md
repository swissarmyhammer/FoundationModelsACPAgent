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
depends_on:
- 01M5CZ35E8P2EZTW5GW3YTW5VX
position_column: todo
position_ordinal: 8a80
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