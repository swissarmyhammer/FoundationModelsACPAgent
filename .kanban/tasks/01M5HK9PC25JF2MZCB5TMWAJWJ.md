---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5hkhvffkaksymdwq11eafsg
  text: |-
    Research: SettingsGraph.rules had no Subscription alias (only Mutation + everywhere), and the Extras toolkit adds no automatic `<noun>Changes` alias, so `settingsChanges` failed with "Cannot query field settingsChanges on type Subscription". The subscription probe needs a first response at once: the test reads `cursor(cwd: nil)`, sets compaction.trigger on USER, and probes `settingsChanges(after: $after) { cursor }` so the change log buffer answers immediately.

    RED: theEndpointConforms with probes [query, subscription] gave 3 problems (field error, no data, no rewrite settingsChanges -> changes). GREEN: added `"Subscription": ["changes": ["settingsChanges"]]` to the alias table; the test passes, problems empty, codes: Self.endpointCodes, no exceptions. Schema golden unaffected (aliases are not in the SDL).

    ### implement — changed
    - evidence: 88bcfa0 (Sources/FoundationModelsACPAgent/Settings/SettingsGraph.swift, Tests/FoundationModelsACPAgentTests/SettingsGraphTests.swift); full `swift test`: 1202 tests in 131 suites passed, 1 known issue
    - next: done (problems empty with both probes, no exceptions)
  timestamp: 2026-10-22T10:47:17.743129+00:00
position_column: done
position_ordinal: ffff8b80
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