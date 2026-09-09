---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'ToolCatalog.sessionSurface: pass the profile''s embedding handle to makeSessionToolsAndStaging, then rerun astropy__astropy-12907'
---
## What

FoundationModelsMultitool card ^zqz1zan: every `searchTools` call of the SWE-bench run `astropy__astropy-12907` (2026-09-09) logged `no embedder configured or catalog not yet embedded; results are keyword-only (BM25 + trigram)`. The agent profile names an embedding model (`AgentConfiguration.defaultEmbedding`, `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`) and `context.profile.embedding` is resident, but `ToolCatalog.sessionSurface(context:)` (`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` lines 124-140) calls `makeSessionToolsAndStaging(librarian: context.profile.flash)` with no embedder.

The Multitool now takes it: `makeSessionToolsAndStaging(librarian:embedder:sampleGenerator:)` with `embedder: RoutedEmbedder? = nil`. The catalog is embedded at the first search, so the call still starts no task. The same Multitool change carries the selection fix (`SearchToolsTool.selectionPreamble`), which made `mlx-community/Qwen3-4B-4bit` answer all ten queries of that run instead of two.

## What to change

- Update the Multitool dependency to the commit that carries card ^zqz1zan.
- Pass `embedder: context.profile.embedding` in `sessionSurface`. The multitool CLI already does the same in `CLIRunner.swift`.

## Acceptance Criteria

- [ ] `sessionSurface` passes the profile's embedding handle.
- [ ] An `acp-agent` run with a profile that names an embedding model logs no `no embedder configured` line (`log show --predicate 'process == "acp-agent"'`).
- [ ] Rerun `uv run bench/swebench_run.py bench/preds.jsonl -i astropy__astropy-12907`. Paste the searchTools table of that run on this card and on ^zqz1zan. The tool log shows write or edit calls, and the patch is not empty.

## Tests

- [ ] A unit test of the session surface asserts that the embedder of a stub profile reaches the mount.
