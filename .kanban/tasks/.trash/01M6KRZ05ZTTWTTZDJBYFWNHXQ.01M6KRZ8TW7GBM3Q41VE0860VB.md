---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Move every test that loads a real model from the unit target to the IntegrationTests package
---
## What
The user said: tests that need a live model belong in the IntegrationTests package (the integration test target), not in the root unit target `FoundationModelsACPAgentTests`. A unit test uses stub or scripted models only. A full unit run hung for 18 minutes at 0% CPU with 7 GB of memory in use (a run in a worktree, 2026-11-04); a unit test that loads a real model is one suspect.

Three live-model suites are already in IntegrationTests (`EmbeddingModelTests`, `ToolCallingTests`, `SkillTriggerTests`). Find the others that are still in the unit target.

## Do
1. Find every test in `Tests/FoundationModelsACPAgentTests/` (and `Tests/FoundationModelsACPAgentTestSupport/`) that loads or runs a REAL model: real MLX or Router model loading (`LiveModelLoader`, `MLXFoundationModels`, embedders, `MetalLibraryTestBootstrap`, a download from Hugging Face, a real `ModelContainer`), or an `.enabled(if:)` / environment gate for a model. A test that only names a model id as a string, or uses `HookLayeredModelLoader` / `QueuedScriptedModel` / scripted stubs, is a unit test: leave it.
2. Move each live-model test to `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/` (git mv; fix imports and the test support it needs; share helpers through `FoundationModelsACPAgentTestSupport` if both targets need them). Keep the test meaning the same. Do not delete or weaken a test; do not mark one as skipped.
3. Make the unit target run with no real model: after the move, a root `swift test` must not load a model. If a test needs a real model only for part of its checks, split it: the stub part stays in the unit target.
4. Record on the task the list of moved tests (file and suite names) and the list of tests you looked at and kept.
5. Do not change a sibling package.

## Acceptance Criteria
- [ ] No test in the unit target loads a real model.
- [ ] The moved tests build and pass (or fail only for lack of a model on the machine) in the IntegrationTests package.
- [ ] The root `swift test` passes and finishes without a hang. Record the run time before and after.

## Tests
- [ ] Root `swift test` (unit only), in the foreground. All pass.
- [ ] `swift build --build-tests` in IntegrationTests passes.

## Workflow
- #tests