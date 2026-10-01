---
comments:
- actor: claude-code
  id: 01m3vrcqdg2n0y0b9h020m6r6p
  text: |-
    Research:
    - Router 79d5dac: `LiveModelLoader.init(reporting:)` sends progress only for a load through the Extras pool protocol (`load(_:)`, `load(key:progressHandler:)`). A router load does not use it. A router load sends the download bytes to the `reporting` closure of `loadLLM`/`loadEmbedder`, and `Router.resolve(profile:reporting:)` puts them into the `ResolutionProgress`.
    - The stderr download bar of acp-agent observes the `ResolutionProgress` that `AgentComposition.compose(reporting:)` gives to `RoutedACPAgent`. Thus the bar does not need the init closure. `LiveModelLoader()` keeps the bar working. The progress tests (`CompositionInterruptTests`, `ProfileResolutionTests`) use their own fake loaders through the `ModelLoader` protocol, and they do not change.
    - Old init calls: `Sources/acp-agent/AgentComposition.swift`, `IntegrationTests/.../ToolCallingTests.swift`, `IntegrationTests/.../SkillTrigger/SkillTriggerTests.swift`, and the code sample in `README.md`.
    - Router did the same manifest work in its own IntegrationTests (10940a5).
  timestamp: 2026-10-01T12:52:53.296021+00:00
- actor: claude-code
  id: 01m3vs12dtm37tj72bfh94817j
  text: |-
    Implementation done:
    - Each old init call is now `LiveModelLoader()`: `Sources/acp-agent/AgentComposition.swift`, `IntegrationTests/.../ToolCallingTests.swift`, `IntegrationTests/.../SkillTrigger/SkillTriggerTests.swift`, and the sample in `README.md`. The `HuggingFace`, `MLXHuggingFace`, `MLXLMCommon` and `Tokenizers` imports are removed.
    - `Package.swift` and `IntegrationTests/Package.swift`: the `liveLoaderProducts` list, the `mlx-swift-lm`, `swift-huggingface` and `swift-transformers` package declarations and their constants are removed. `MLXLMCommon` went too, because only the macro calls used it. mlx-swift-lm still comes into the graph through Router.
    - The stderr download bar does not change. It observes the `ResolutionProgress` of the resolve, and a router load does not use the init callback of `LiveModelLoader`. For this reason the call is `LiveModelLoader()` and not `LiveModelLoader(reporting:)`.
    - Discovery: `IntegrationTests/Package.resolved` is not in git and had its own old pins (Router c49e453), so the first IntegrationTests build still saw the old init. `swift package update` in IntegrationTests moved it to Router 79d5dac, Extras c5ca65a, Ranker 39e3717, CodeContext 0220e9b, the same as the root.
    - No new test: this card changes a call to a dependency API and the manifests. The existing progress tests and the real-model integration suites cover the behavior.
  timestamp: 2026-10-01T13:03:59.930333+00:00
- actor: claude-code
  id: 01m3vs181exrdbbge5nb43p6m1
  text: |-
    Errors from the dependency refactor that are NOT part of this card (not fixed here, for routing):
    1. Build errors: none. `swift build --build-tests` is clean at the root and in IntegrationTests. There is no TelemetryCapture log record error from Extras 42ca5b5 and no Ranker TextEmbedding / selection factory build error at these pins.
    2. Unit test failure (root `swift test`, 1 of 668 tests):
       `Tests/FoundationModelsACPAgentTests/ToolCatalogTests.swift:149:9` — `theSessionSurfaceHandsTheProfileEmbedderToSearchTools()`: `Expectation failed: embedder.batches == [catalogBlocks]`. The recorded batches start with `["vector length probe"], ["vector length probe"]` before the catalog batch. Cause: CodeContext 0220e9b `MeasuredEmbedder` (`Sources/FoundationModelsCodeContext/Embedding/MeasuredEmbedder.swift`, `probeText = "vector length probe"`) embeds one probe text to learn the vector length, because the Ranker `TextEmbedding` has no `dimension` now. This is in the area of ^zyxtq (01M3QMDSFRKKZNME0VTA3ZYXTQ).
    3. Build warning that was there before this card (it is in each earlier build in the shell history): `warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`. It comes from the SwiftPM build of the mlx-swift `Cmlx` bundle.
  timestamp: 2026-10-01T13:04:05.678378+00:00
- actor: claude-code
  id: 01m3vs1ebr265vszk93y9ktevt
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/acp-agent/AgentComposition.swift, Package.swift, IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ToolCallingTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SkillTrigger/SkillTriggerTests.swift, README.md. `swift build --build-tests`: clean at the root and in IntegrationTests. `swift test --package-path IntegrationTests`: 29 tests in 11 suites pass (real models load through `LiveModelLoader()`). Root `swift test`: 667 of 668 pass; 1 failure, ToolCatalogTests.swift:149:9, from the CodeContext vector length probe (see the comment above), which is not in this card.
    - open: the "CI is green on the pushed commit" item and the push. The requester said not to commit and not to push. The root `swift test` item stays open until the card 01M3QMDSFRKKZNME0VTA3ZYXTQ (or a new card) corrects ToolCatalogTests.
    - next: /review.
  timestamp: 2026-10-01T13:04:12.152430+00:00
position_column: doing
position_ordinal: '8180'
title: Adopt LiveModelLoader(reporting:)
---
## What
FoundationModelsRouter changed the public initializer of `LiveModelLoader` (pushed as ce67176/afd9b5a, CI green). The old `LiveModelLoader(downloader:tokenizerLoader:weightsLocation:…)` is deleted; the new one is `LiveModelLoader(reporting: @escaping @Sendable (DownloadProgress) -> Void = { _ in })`. Models load through the Extras `MLXModelLoader`, so the caller gives no downloader and no tokenizer loader.

```swift
let router = Router(recordingsDir: dir, loader: LiveModelLoader())
```

- Change each call of the old initializer to `LiveModelLoader()` or `LiveModelLoader(reporting:)`: `Sources/acp-agent/AgentComposition.swift` (~line 262), `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ToolCallingTests.swift` (~line 129) and `IntegrationTests/.../SkillTrigger/SkillTriggerTests.swift` (~line 99).
- Remove the `#hubDownloader()` / `#huggingFaceTokenizerLoader()` imports and the `HuggingFace`, `Tokenizers` and `MLXHuggingFace` products that only those calls used (in `Package.swift` and `IntegrationTests/Package.swift`).
- `swift package update`, confirm the Router revision is afd9b5a or later; push to `origin main` when green.

## Acceptance Criteria
- [x] No file calls `LiveModelLoader(downloader:`.
- [x] The package and its IntegrationTests build.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `swift build` and `swift test` pass.
- [x] `swift test --package-path IntegrationTests` passes (the real-model resolve still loads the models).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool