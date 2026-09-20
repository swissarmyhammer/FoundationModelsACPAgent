---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The skills search asks the flash model for JSON with no grammar, and a bare `[explore]` fails the whole skills call
---
## What

SWE-bench run of 2026-09-18 14:13, instance `django__django-13447`. The model called the `skills` tool one time, to find the `explore` skill. The call failed:

```
This operation failed while executing. Cause: Encountered content that cannot be completed into valid JSON
Text: [explore]
```

The model did not try again, and it never loaded a skill.

## Cause

1. The `skills` search op runs the selection tier of FoundationModelsRanker on the `flash` slot, through `SelectionAgentSession` (`Sources/FoundationModelsACPAgent/Tools/SelectionAgentSession.swift`).
2. `SelectionAgentSession` implements only `respond(to:)`, which gives plain text. The tier calls `respond(to:generating: Selection.self)`, and the Ranker default of that method sends the prompt as plain text and then does `T(GeneratedContent(json: raw))`. No grammar constrains the answer.
3. The flash model chose the correct skill, but it wrote `[explore]`, not `{"ids": ["explore"]}`. The JSON parse threw, and `OperationError.executionFailed` made the whole `skills` call fail.

Multitool does not have this fault. Its `searchTools` selection uses `idEnumGrammar(ids:)` (`Discovery/SelectionGrammar.swift`): an xgrammar JSON schema that forces `{"ids": [...]}` with each id from the candidate set.

## The work

1. Give `SelectionAgentSession` a `respond(to:generating:)` that uses grammar-constrained generation of the routed flash model. It must use a JSON schema for `Selection` (`{"ids": [string]}`), and if possible an enum of the candidate skill ids, as Multitool does. If Router does not give a public guided `respond` on a `RoutedSession`, make a card in FoundationModelsRouter for it, and stop here.
2. A regression test: a scripted flash model that answers only in the shape that the grammar allows gives a `Selection`; and with no grammar support, the failure is not a bare JSON error.
3. Look at a second improvement: when the search fails, `use skill` with the id that the model already knows (`explore`) must still work. The model did not try it because the error text gave no next step.

Do not change code while a SWE-bench run is active. #skills #bench