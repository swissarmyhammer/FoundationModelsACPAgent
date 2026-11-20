---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7x4jv74czyyrq1ngvzx5vqt
  text: |-
    Research done (2026-11-20).
    - Upstream: issue ml-explore/mlx#4832 (open). Fix PR ml-explore/mlx#4903 (open, head 537b955bbb4): it does not send `bv` when `split_d` is true. No mlx-swift release has the fix: 0.33.0 and main 00afc1dde both have mlx 36969c094.
    - Owner: only mlx-swift-lm sets the mlx-swift rule (Package.swift:103, `.upToNextMinor(from: "0.33.0")`).
    - Why only the 9B: the mlx-swift-lm prefill kernel (PrefillAttentionKernel.swift:49, 508) runs only when the query heads for each KV head are a multiple of 3. Qwen3.8-27B has 24/4 = 6. Qwen3.5-9B has 16/4 = 4, so it goes to MLXFast.scaledDotProductAttention (DecodeAttentionKernel.swift:574). With chunks of 2048 (Qwen35PrefillPolicy.swift:19), MLX selects dsplit at 1024 or more query tokens.
    - Workaround proposed to mlx-swift-lm: a `maximumPrefillStepSize` of 1023 or less for Qwen 3.5 models whose head ratio is not a multiple of 3 (Qwen35.swift near line 1258).
    - Request sent to the session mlx-swift-lm-e8. That session decides the fix and sends the sha on `stable`. Work item 1 is done.
  timestamp: 2026-11-20T18:47:58.436642+00:00
- actor: claude-code
  id: 01m7x8dzwtndhkzghggskswepe
  text: |-
    Work item 2 result (2026-11-20): the fix works on the M5 Max.

    - `swift package update mlx-swift-lm` in the main tree of FoundationModelsACPAgent: the pin is `stable` at 74e499b5d5627b4b0f7172ffd88561a52fbfd524. No llama.cpp clone, no new repository in `.build/repositories`.
    - One debug build of `acp-agent`: "Build complete!". `Qwen35.o` of MLXLLM is new.
    - A session with the bundled profile `small` and the same 5 prompts as before: no fatal error, 5 of 5 answers are correct, 5 of 5 turns end with `end_turn`.
    - Decode 46.0 tokens per second (1910 tokens out in 41.5 s of decode, 19 MTP generation calls), MTP acceptance 0.862 (1154 of 1338 drafted tokens).
    - Details are on ^wx4ewrs.
  timestamp: 2026-11-20T19:55:13.690368+00:00
position_column: done
position_ordinal: ffffffb780
title: 'The small profile (Qwen3.5-9B) stops the agent on an M5 Mac: the MLX JIT kernel attention_nax_dsplit does not compile'
---
Found by ^wx4ewrs (2026-11-20).

## Fault

On an Apple M5 Max (macOS 27.2), a session with the bundled profile `small` loads, but the first prompt stops the `acp-agent` process:

`MLX/ErrorHandler.swift:345: Fatal error: [metal::Device] Unable to build metal library from source`

The Metal compiler cannot build the JIT kernel `steel_attention_dsplit_bfloat16_bq64_bk32_bd256_bv256_wm4_wn2_maskbfloat16` ("explicit instantiation of 'attention_nax_dsplit' does not refer to a function template").

## Cause (from the code in .build/checkouts/mlx-swift, mlx submodule 36969c094)

- `get_steel_attention_nax_kernel` in `mlx/backend/metal/jit_kernels.cpp` gives the template arguments `T, bq, bk, bd, bv, wm, wn, mask` to both `attention_nax` and `attention_nax_dsplit`.
- The template `attention_nax` in `steel_attention_nax.h` has a `BV` parameter. The template `attention_nax_dsplit` has no `BV` parameter. Thus each JIT instantiation of the dsplit kernel is wrong.
- `scaled_dot_product_attention.cpp` selects the dsplit NAX kernel when NAX is available (M5), the head dim is 256, and the query length is 1024 or more. Qwen3.5-9B has head dim 256.
- The fault is not from `kvBits: 8`: the same models with no `kvBits` give the same fault.
- `medium` (Qwen3.8-27B, head dim 256 too) answers on the same build. Find why the 27B path does not reach the dsplit kernel (for example, a smaller prefill step).

## Work

- [x] Find the owner of the fix: the mlx-swift pin of the family, or the upstream mlx. Do not write to the board of a different package; send the request to that session.
- [x] When the fix is on the pin, run a session with `small` on an M5 Mac, and record load time, memory, window, tokens per second and MTP acceptance on ^wx4ewrs.

## Tests

- A real Mac check only (an M5 Mac). No unit test in this package. #profiles #d203 #acpa-23