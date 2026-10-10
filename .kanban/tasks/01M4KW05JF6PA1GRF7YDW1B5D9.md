---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: 'cli-plan.md §9: the Gate column names ACP_TIER3=1 and ACP_TIER4=1, but no suite has an environment gate'
---
## Problem

The `Gate` column of the test table in `cli-plan.md` §9 gives `ACP_TIER3=1` for each tier-3 row and `ACP_TIER4=1` for the tier-4 row. The suites carry no environment gate. The package boundary is the selection: the root `swift test` does not see the `IntegrationTests` package, and `swift test --package-path IntegrationTests` runs it (see the header comments of `ClientInteropTests`, `TierThreeFixture` and the `IntegrationTests/Package.swift` doc). The org test contract forbids an environment variable that selects a test.

Found while doing ^dn561z8. That task changed one tier-3 row and kept the column as it is, because the column is outside its scope.

## Change

- [ ] Replace the `Gate` column of `cli-plan.md` §9 with the target that selects each row: `none` (root unit target) or the `IntegrationTests` package. Check whether a tier-4 suite exists; if it does not, say so in the row.

## Tests

- [ ] `rg -n "ACP_TIER" cli-plan.md` gives no match. This is a document change, so no code test applies.

#docs