---
position_column: todo
position_ordinal: '9880'
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
- [ ] No file calls `LiveModelLoader(downloader:`.
- [ ] The package and its IntegrationTests build.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] `swift build` and `swift test` pass.
- [ ] `swift test --package-path IntegrationTests` passes (the real-model resolve still loads the models).

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool