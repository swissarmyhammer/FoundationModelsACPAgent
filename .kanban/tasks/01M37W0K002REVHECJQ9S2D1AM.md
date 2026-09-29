---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3nhjwkhc7tswvje4wpsf2wh
  text: |-
    Research (2026-09-28):
    - This repository has no `grepCode` code. The only hit is `bench/code-context.config.yaml`. The verb comes from the FoundationModelsCodeContext package.
    - The cause is in `FoundationModelsCodeContext/Sources/FoundationModelsCodeContext/Ops/GrepCode.swift`. `GrepCode.matchChunk` returns one `GrepCodeMatch` for each `ts_chunks` row whose text matches. That match holds the full chunk text, its start and end lines and its `symbolPath`. The outer chunk (the class) contains the text of each inner method, so the class chunk matches too. `run` sorts by `(filePath, startLine)` and does not remove a chunk that contains a smaller matching chunk. Thus the class comes first and the 1,500-token tool cap cuts the answer.
    - A possible fix in that package: for each match line, keep only the innermost chunk that contains it (or answer with the matching lines, their line numbers and the enclosing `symbolPath`). Add a test on a class with one matching method.
    - The FoundationModelsCodeContext board has no card for this. I searched its `.kanban/tasks` for `grepCode`, `outermost`, `innermost` and `enclosing`: the `grepCode` cards are all done (port, tools, tracing) and none is about the outermost chunk.
    - I did not change the package, and I did not make a card on its board. The user rule says: stop and discuss a task on a family project with the user first.

    ### implement — stuck
    - evidence: no files changed. The fix belongs in FoundationModelsCodeContext (`Ops/GrepCode.swift`), not in this repository. No card for it exists on the FoundationModelsCodeContext board.
    - next: the user decides to open a card on the FoundationModelsCodeContext board (for example with `sah --cwd /Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext tool kanban task add`). This card stays open until that fix ships and the pin moves.
  timestamp: 2026-09-29T02:58:28.593812+00:00
- actor: claude-code
  id: 01m3nhk9ajz53n88vryrzpg3vg
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no files changed. The fix belongs in FoundationModelsCodeContext Sources/FoundationModelsCodeContext/Ops/GrepCode.swift (matchChunk and run return each matching chunk, the outer class also). The FoundationModelsCodeContext board has no open card for it.
    - test, commit, review: not run
    - next: a person must decide if a card goes on the FoundationModelsCodeContext board.
  timestamp: 2026-09-29T02:58:41.618326+00:00
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