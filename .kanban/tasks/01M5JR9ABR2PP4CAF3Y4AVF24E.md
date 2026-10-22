---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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