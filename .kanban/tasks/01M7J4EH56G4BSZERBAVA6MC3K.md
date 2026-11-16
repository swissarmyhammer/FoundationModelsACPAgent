---
assignees:
- claude-code
position_column: done
position_ordinal: fffff180
title: The models GraphQL endpoint for the Models pane
---
From testudoapp-75 (TestudoApp ^453zgr3, D183 (c), D100 (d)).

- `models`: one row for each slot (STANDARD, FLASH, EMBEDDING, DECISION) with repo, drafter, file, sizeBytes (model + drafter), presentBytes, state, configValue.
- `choices(slot:)`: the models that a slot can take. Interim: the configured candidates and the builtin candidates; use Router `choices(for:)` when it lands.
- `changes(after:)`: slot changes (apply at the next launch) and disk changes.
- A top-level tool with GraphQLEndpointTool. No model load and no download.