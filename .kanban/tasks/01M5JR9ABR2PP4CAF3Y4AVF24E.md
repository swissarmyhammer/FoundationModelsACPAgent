---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5k4w13qty23g16bprekf3h0
  text: |-
    Research (picked up 2026-10-22):
    - Router pin was d1528d72; 4cb3879b is two commits on top (7c42e271 feat + kanban). Only Package.swift (adds swift-huggingface, HuggingFace product), LiveModelLoader(…tokenProvider:), HuggingFaceMetadataSource(…tokenProvider:), Router.cacheDirectory changed. Extras pin 78d25320 already has MLXModelLoader(cacheDirectory:tokenProvider:), so no Extras bump needed. Root Package.resolved is gitignored: the pin bump is a local edit of the Router revision only, then `swift package resolve` (no `swift package update`). IntegrationTests/Package.resolved already pins Router ee6e2bc8, a descendant of 4cb3879b, so it needs nothing.
    - AgentHome already gives routerCacheDirectory = <local>/router for makeCustom (from ^98a44n7) and nil for XDG (the CLI keeps the user caches folder). So the cache half was wired; this card adds the test through Router.cacheDirectory.
    - Decision: the provider goes on compose, not on AgentHome. AgentHome is Equatable and tests compare homes with == (HomeOptionsTests); TokenProvider is an enum with closures and is not Equatable. The card allows "AgentHome (or compose)".
    - Only ComposedAgent builds a live router/loader; doctor's SystemModelResolver uses HuggingFaceMetadataSource() with the .environment default, which is the CLI default, so it is unchanged.
    - Pitfall found: URL.standardizedFileURL drops /private only for paths that exist, so comparing a not-yet-made router folder against an existing local root with standardized paths fails. The test compares plain paths.
  timestamp: 2026-10-23T01:09:11.415480+00:00
- actor: claude-code
  id: 01m5k4we26xs350a0d3s8k1c0e
  text: |-
    Implementation landed (not committed, per the brief):
    - Router pin 4cb3879b6114a10e67618a0712610e0924a3c24d in Package.resolved (local, gitignored); Package.swift declares swift-huggingface (same URL and 0.9.0 floor as Router/Extras) and links HuggingFace to the library and the unit test target.
    - ComposedAgent.compose(... huggingFaceTokenProvider: TokenProvider = .environment, reporting:). makeRouter is now internal and takes huggingFaceTokenProvider; the live path builds Router(metadataSource: HuggingFaceMetadataSource(tokenProvider:), loader: makeLiveModelLoader(modelCacheDirectory:tokenProvider:)). The CLI passes nothing, so it keeps .environment (doc added in AgentComposition.compose). DocC links to compose updated in AgentComposition.swift and GatedStubModel.swift.
    - TDD: HuggingFaceTokenProviderTests (4 tests) written first; RED = compile failure ('makeRouter' is private, extra argument 'huggingFaceTokenProvider'). GREEN after the change. Cases: Router.cacheDirectory under home.local for a custom home; fixed provider reaches the loader (Mirror loader.modelLoader.tokenProvider); the router's sizing provider (Mirror metadataReader.source.tokenProvider) sends "Bearer host-token" on both sizing GETs to a StubURLProtocol host; XDG home with HOME/XDG_CONFIG_HOME/XDG_DATA_HOME pointed at an empty folder sends the host token on both paths and the folder stays empty.
    - Interpretation recorded: case 3 ("no token file is read from there") is read as: with the host provider, neither path consults the environment provider, and the empty folder stays empty. TokenProvider.environment reads the process environment and ~ expansion, not the env dict given to compose, so a planted file in that folder could not be read in any case.
    - ModelCacheDirectoryTests: the two makeLiveModelLoader calls now pass tokenProvider: .environment (signature change).
  timestamp: 2026-10-23T01:09:24.678643+00:00
- actor: claude-code
  id: 01m5k4wn3gx65aaavm3q6k81hg
  text: |-
    ### implement — changed
    - evidence: 7 files — Package.swift, Package.resolved (local, gitignored: Router pin 4cb3879b only), Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Configuration/GatedStubModel.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/ModelCacheDirectoryTests.swift, Tests/FoundationModelsACPAgentTests/HuggingFaceTokenProviderTests.swift (new). `swift test --filter HuggingFaceTokenProviderTests`: RED (compile) then 4/4 pass. Full `swift test`: 1237 tests in 137 suites passed, 0 failures (1 known issue is the deliberate withKnownIssue in HarnessSmokeTests). Bench: `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'`: 265 OK (1 skip: swebench not installed, pre-existing). Only build warning is the pre-existing mlx-swift_Cmlx.bundle "missing creator" Swift Build warning.
    - next: /review. Not committed; release binary not rebuilt.
  timestamp: 2026-10-23T01:09:31.888427+00:00
- actor: claude-code
  id: 01m5k50a8heghv2hnrjdnj3ng3
  text: |-
    ### test — green
    - evidence: `swift test` — 1237 tests in 137 suites passed, 0 failed, 0 skipped; the 1 known issue is the deliberate withKnownIssue in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps. `python3 -m unittest` in bench — 265 run, OK, 1 skip (swebench not installed on system python 3.8); rerun with swebench==5.0.2 on python 3.12 (`uv run --no-project --python 3.12 --with swebench==5.0.2 python -m unittest`) — 265 run, OK, 0 skipped. Only compiler-side output: SwiftPM build-system note "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency product, not from package sources. No files changed.
    - next: commit
  timestamp: 2026-10-23T01:11:31.857077+00:00
- actor: claude-code
  id: 01m5k550v74sm2thk7xgnb3593
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (642a076) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 6 files reviewed, 2 .kanban files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-23T01:14:06.055384+00:00
- actor: claude-code
  id: 01m5k55bd794a1kenahg32011h
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files (Package.swift, ComposedAgent.swift, GatedStubModel.swift, AgentComposition.swift, 2 tests, local Router pin 4cb3879b)
    - test: green — swift test 1237 passed; bench unittest 265 OK
    - commit: 642a076
    - review: clean — 0 findings
  timestamp: 2026-10-23T01:14:16.871663+00:00
position_column: done
position_ordinal: ffff8f80
title: 'AgentHome: the host gives the Hugging Face token provider, and Router''s metadata cache follows the local home'
---
A follow-up of ^98a44n7 (AgentHome), which recorded two parts that wait on other packages. This is one of them; the other is the CodeContext index folder, still open.

Router main 4cb3879b (^gnte6er) and Extras ^d7dtghb have:
- `LiveModelLoader(reporting:cacheDirectory:tokenProvider: TokenProvider = .environment)`;
- `HuggingFaceMetadataSource(endpoint:session:tokenProvider:)`, which sends `Authorization: Bearer`;
- `Router.cacheDirectory: URL`, public, nonisolated and read-only.
`TokenProvider` is the swift-huggingface type; a target that names it links the `HuggingFace` product.

## Change
- AgentHome (or compose) takes a `TokenProvider`. The CLI default is `.environment` (HF_TOKEN, then ~/.cache/huggingface/token, as today). The Mac app gives its own provider, for example one that reads the Keychain.
- ACPAgent passes it to LiveModelLoader and to the metadata source.
- Router's metadata cache folder is under the local home.

## Done when
- A failing test first (TDD), with these cases:
  - with a custom AgentHome, `Router.cacheDirectory` is under `home.local`;
  - a fixed token provider reaches the loader and the metadata source, and a test double sees the bearer header;
  - with HOME and XDG pointed at an empty folder, no token file is read from there.
- The full `swift test` and the bench tests pass. #home