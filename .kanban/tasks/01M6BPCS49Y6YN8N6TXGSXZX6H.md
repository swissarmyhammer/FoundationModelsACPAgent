---
comments:
- actor: wballard
  id: 01m6bycbjmfws43nnfnkgcb80e
  text: 'Done in e5c07e2: defaultEmbedding is erjigit17/embeddinggemma-300m-ane-coreml, tests and README updated, 1281 tests pass. Format detection by repo id works through Router HubModelLoader. Open: a local path in the config waits for Router ^y18w1dp and Extras ^3mnxzqf. Also check the semantic search with the 300m vector size in a live run.'
  timestamp: 2026-11-01T16:16:47.188723+00:00
position_column: done
position_ordinal: ffff9680
title: Default embedding is the CoreML embeddinggemma; config takes a path of either format
---
Goal: erjigit17/embeddinggemma-300m-ane-coreml is the default model of the profile embedding slot, and the config accepts a repo id or a local path of a CoreML model or an MLX model, with the format found by itself.

Steps:
1. Set ProfileConfiguration.defaultEmbedding (AgentConfiguration.swift) to erjigit17/embeddinggemma-300m-ane-coreml.
2. Update the tests, the builtin config comments, cli-plan.md and the docs that name Qwen3-Embedding-0.6B-4bit-DWQ.
3. Make the embedding slot accept a local path in the YAML. Add a config test for a repo id, a CoreML path and an MLX path.
4. Check the doctor (ProfileDoctor) and the ConfigOptions embedding option for a path.
5. Check that the code context semantic search works with the 300m dimension.

Blocked by cards on other boards (a card cannot depend across boards):
- FoundationModelsRouter ^zpcsp86: LiveModelLoader loads CoreML embedding models through HubModelLoader.
- FoundationModelsExtras ^3mnxzqf: HubModelLoader detects the model format from a local path.
- FoundationModelsRouter: ModelRef accepts a local model path (the third card).
Do not start step 1 before the Router card ^zpcsp86 is done: the default would fail to load.