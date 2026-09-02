---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
position_column: todo
position_ordinal: '9e80'
title: Wire the compaction TokenBudget into session/new when Router shows the resolved context
---
## What
`session/new` (^63bbyr8) passes `budget: nil` to `profile.standard.makeSession(...)`, so automatic compaction is off.

Cause: `TokenBudget` requires a `limit` in tokens. Router does not show the resolved working context through its public API. `SlotResolution.contextTokens` and `RoutedModel.resolution` have `package` access. The config `compaction:` section carries only fractions (`trigger`, `target`, `hardCeiling`) and `toolOutputLimit` (plan.md §2.4: the context comes from the model).

## Steps
- [ ] Add a public read of the resolved standard-slot context to FoundationModelsRouter (for example `RoutedModel.contextTokens`), or use an equivalent public door when one lands.
- [ ] In `SessionSetup`, build `TokenBudget(limit: <resolved context>, trigger:, target:, hardCeiling:, toolOutputLimit:)` from `CompactionConfiguration` and pass it as `budget:`.
- [ ] Remove the marked TODO in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`.
- [ ] Test: a session made with a config `compaction:` section carries the derived budget (asserted through visible behavior or a recorded sidecar field).

## Acceptance Criteria
- [ ] `session/new` passes a non-nil `budget` derived from the compaction config and the model's resolved context.
- [ ] `swift test` green.