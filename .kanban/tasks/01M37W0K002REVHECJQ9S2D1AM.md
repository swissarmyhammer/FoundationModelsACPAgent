---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: grepCode returns the outermost symbol, so a hit in one method gives back the whole class
---
## What happens

`tools.code_context.grepCode` answers each match with the whole OUTERMOST indexed symbol that holds it. A match in one method of a large class comes back as the entire class.

## Evidence

The rerun of django__django-13964 on 2026-09-23 (transcript `bench/preds.code-context.transcripts/django__django-13964/`): after loading the `explore` skill, the model called `grepCode({ pattern: "_prepare_save_values|def _do_insert|def _save_table", filePattern: "django/db/models/base.py" })`. The answer was ONE chunk: symbol `Model`, lines 403 to 2090. The 1,500-token tool cap then cut it. The model's reasoning: "The grep returned the entire file (because it matched 'class Model')". It switched to `tools.files.grep` and did not use the code context again for the rest of the 51 minutes.

Reproduced on 2026-09-23 on a 166-line Python file, with the shipped model:

| Verb | Query | Answer |
|---|---|---|
| `grepCode` | `def _save_table` | symbol `Model`, lines 0 to 164 |
| `searchSymbol` | `_save_table` | symbol `Model._save_table`, lines 163 to 164 |

Thus the index knows the method as its own symbol, and `grepCode` reports the container.

## What must change (in FoundationModelsCodeContext)

`grepCode` must answer each match with the INNERMOST symbol that holds it, or with the matching lines, their line numbers and the path of the enclosing symbol. A 1,700-line class for one matching line is not an answer that a model can use, and a tool cap cuts it anyway.

## Done on our side

The skills (swissarmyhammer/skills, branch `code-context`, commit 0bf6baa) now send a name to `searchSymbol` or `getSymbol`, say that a `grepCode` hit is the whole outermost symbol, and name `tools.files.grep` as the verb for exact lines. This card stays open for the package fix; take it to the session of FoundationModelsCodeContext.

## Acceptance

On the 166-line file above, `grepCode({ pattern: "def _save_table" })` answers with `Model._save_table` (lines 163 to 164) or with line 163 and its enclosing path — not with lines 0 to 164.

#upstream #code-context