---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'EXTRAS-11 settings: the conformance test probes a subscription alias too (probes: [query, subscription])'
---
From the Multitool session's GraphQL coordination card: SettingsGraph must pass `GraphQLEndpointConformance.problems(of:scope:probes:codes:exceptions:)` with no exceptions, with alias probes for queries AND subscriptions.

## Today
`SettingsGraphTests.theEndpointConforms` (Tests/FoundationModelsACPAgentTests/SettingsGraphTests.swift:90-104) uses the one-probe form `probe:`, with a query alias only: `setting(key:)` → `keyPath`. It passes `codes: Self.endpointCodes` and no exceptions; the last exception went in 2e5fbbd. The schema golden and descriptions tests pass.

## Change
- Use `probes: [queryProbe, subscriptionProbe]`.
- The subscription probe uses a `GraphQLAliasProbe` of kind `.subscription` that calls an alias the endpoint rewrites, for example `settingsChanges` → `changes` (EXTRAS-9 rule 9: the alias tables accept `<noun>Changes`). First check that SettingsGraph's alias table has that alias. If it does not, add it (rule 9), with a test first.

## Done when
- A failing test first (TDD), if the alias is missing.
- `problems(...)` is empty with both probes, the codes, and no exceptions.
- The full `swift test` passes. #extras-9