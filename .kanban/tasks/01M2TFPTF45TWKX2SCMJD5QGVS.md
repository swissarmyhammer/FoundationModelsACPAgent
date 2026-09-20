---
assignees:
- claude-code
position_column: done
position_ordinal: de80
title: session/new must not wait for the code context index
---
On 2026-09-18 the SWE-bench run failed: `session/new` waited for `CodeContext.start()`, which does one full index pass with an embedding of each chunk. For the django clone (44,532 chunks) the pass did 273 chunks in 8 minutes, and the bench client stopped at its 600 second limit. The next instance then got `Internal error (-32603)`, because the first code context was still active on the same path.

Work:
- `ToolCatalog.composeCodeContext` starts the context in a background task. The stop closure cancels that task, waits for it, and then stops the context.
- A `tools.codeContext.semanticSearch` key (default `true`). With `false`, a `ZeroTextEmbedding` takes the place of the profile embedder.
- `bench/code-context.config.yaml` sets `semanticSearch: false`.
- A regression test: with an embedder that never returns, `ToolCatalog.makeRegistry` still returns, and the stop closure returns.
- README rows for the two keys.

Acceptance: three sessions in sequence on one path, in one agent process, each answer `session/new` in less than 2 seconds on a django clone. #code-context