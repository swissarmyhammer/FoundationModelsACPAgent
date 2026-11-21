---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7wxwhqa8vrzhhc8b5qzm06n
  text: |-
    Research done (2026-11-20).

    - Method: `acp-agent acp --telemetry-file <file>` (debug build, "Build complete!"), driven over ACP stdio by a Python driver in the scratchpad. Each run has its own folder. The project layer `<folder>/.acp-agent/config.yaml` sets `profile`. Two project-layer profile files `large-kv8` and `medium-kv8` have the models of `large` and `medium` with `kvBits: 8`. The bundled profile files do not change.
    - The `models` GraphQL endpoint (`_sah/graphql/execute`, endpoint `models`, query `profiles(cwd:)`) gives `fit`, `contextTokens`, `requiredBytes` and `budgetBytes` of each profile.
    - The telemetry spans give the load times, the window of the resolve (`context.tokens`, `kv_cache.bits`), and for each generation call `tokens.out`, `generation.decode_ms` and the MTP counts (`generation.mtp.drafted_tokens`, `generation.mtp.accepted_tokens`).
    - Discovery: `acp-agent acp` composes the agent and starts the resolve and the model load before it answers `initialize`. A client gets no `initialize` answer while the download runs.
    - Discovery: the KV cache of Qwen3.8-27B is 16 full-attention layers x 4 KV heads x 256 head dim. In fp16 that is 64 KiB for each token for each cache. The fit counts two caches (standard and flash). At the native window 262144 that is 32 GiB. Thus on this Mac (128 GB) each profile fits at the native window, and the window gain of `kvBits: 8` shows only on a smaller Mac. The comparison of windows for the target Macs is calculated from `requiredBytes`.
    - The download speed from the Hub is slow (about 1 to 2 MB/s at the start). The download of `small` takes long.
  timestamp: 2026-11-20T16:50:56.362905+00:00
- actor: claude-code
  id: 01m7x4046z66ykcv527fz4tjnj
  text: |-
    Work item 1 (`small` on a real Mac): BLOCKED. The session loads, but the first answer stops the agent process.

    - Mac: Apple M5 Max (Mac17,6), 128 GB, macOS 27.2 (26B123). Debug build of `acp-agent` at 9a87591.
    - Download through the product path (resolve at the launch of `acp-agent acp`): `mlx-community/Qwen3.5-9B-4bit` 5.98 GB in 3842 s (about 1.5 MB/s from the Hub). The client gets no `initialize` answer until the download ends.
    - Load (models in the disk cache): resolve 3.1 s. standard 0.77 s (footprint 10.65 GB, `kv_cache.bits: 8`, drafter `mlx-community/Qwen3.5-9B-MTP-4bit`), embedding 1.0 s, decision 1.2 s (footprint 3.88 GB, `kv_cache.bits: 8`). `session/new` 1.0 s.
    - Window: `context.tokens` 262144 (the native window; this Mac has a budget of 115448725504 bytes). Router resident gauge: 19.4 GB.
    - Fault: at the first prompt the process stops with `MLX/ErrorHandler.swift:345: Fatal error: [metal::Device] Unable to build metal library from source`. The Metal compiler cannot build the JIT kernel `steel_attention_dsplit_bfloat16_bq64_bk32_bd256_bv256_wm4_wn2_maskbfloat16` (`steel_attention_nax.h`: "explicit instantiation of 'attention_nax_dsplit' does not refer to a function template").
    - Cause (read in `.build/checkouts/mlx-swift`, mlx submodule 36969c094): `get_steel_attention_nax_kernel` in `mlx/backend/metal/jit_kernels.cpp` gives the template arguments `T, bq, bk, bd, bv, wm, wn, mask` to both `attention_nax` and `attention_nax_dsplit`. The template `attention_nax` has a `BV` parameter, but the template `attention_nax_dsplit` has no `BV` parameter. Thus each instantiation of the dsplit kernel is wrong. MLX selects the dsplit NAX kernel when NAX is available (M5), the head dim is 256, and the query length is 1024 or more (`scaled_dot_product_attention.cpp`). Qwen3.5-9B has head dim 256, and the first prompt of a session has about 14K tokens.
    - The fault is not from `kvBits: 8`: a project profile with the same models and no `kvBits` stops with the same error.
    - `medium` (Qwen3.8-27B, also head dim 256) answers on the same build. Thus the 27B path does not reach the dsplit kernel (probably a smaller prefill step). Not verified.
    - Thus no tokens per second and no drafter acceptance for `small`. A new task records the fix.
  timestamp: 2026-11-20T18:37:45.055108+00:00
- actor: claude-code
  id: 01m7x8e6cg7bv6nkvwxfsb5qyf
  text: |-
    Work item 1 (`small` on a real Mac): DONE with the fix of ^xgqst2y (mlx-swift-lm `stable` 74e499b, new debug build).

    Mac: Apple M5 Max (Mac17,6), 128 GB, macOS 27.2. Budget (`recommendedMaxWorkingSetSize`): 115448725504 bytes.

    - Download (first run, product path): `mlx-community/Qwen3.5-9B-4bit` 5.98 GB in 3842 s (about 1.5 MB/s from the Hub).
    - Load (models in the cache): resolve 20.3 s. standard 1.5 s (footprint 10.65 GB, `kv_cache.bits: 8`, drafter `mlx-community/Qwen3.5-9B-MTP-4bit`), embedding 17.0 s (a cold Core ML load; 1.0 s in the earlier runs), decision 1.3 s (footprint 3.88 GB, `kv_cache.bits: 8`). `session/new` 2.3 s.
    - Window: `context.tokens` 262144 (native). On this Mac each profile fits at the native window.
    - Memory: Router resident estimate 19.4 GB. Measured process memory (`top` MEM) at most 8.7 GB, RSS at most 3.9 GB. The KV cache grows with the tokens, so the measured memory is less than the estimate.
    - Speed: 46.0 tokens per second of decode (1910 tokens in 41.5 s, 19 generation calls of 32 to 359 tokens). Prefill of the first prompt (14154 tokens, no cache): 10.0 s.
    - MTP: each call speculated; acceptance 0.862 (1154 of 1338 drafted tokens).
    - Answers: 5 of 5 correct (391; $0.05; "marigold" with a tool call; a correct `is_prime`; a correct text of about 250 words on collisions).
    - Note: debug build. A second SwiftPM process (PID 3255, not from this session) used this `.build` at the same time as the update. Other sessions on the Mac ran Swift builds during the runs, so the speeds can be a little low.
  timestamp: 2026-11-20T19:55:20.336895+00:00
- actor: claude-code
  id: 01m7x8er2je7ztrxh1gkts0wy9
  text: |-
    Work item 2, part `medium` (debug build at 9a87591 with mlx-swift-lm c1b3d5e; the fix of ^xgqst2y changes only Qwen3.5, so the 27B path is the same). Same 5 prompts, one session for each profile, one run each.

    | | `medium` (bundled, KV fp16) | `medium-kv8` (same models, `kvBits: 8`) |
    |---|---|---|
    | Resolve | 4.8 s | 4.2 s |
    | standard footprint (estimate) | 33.47 GB | 25.42 GB |
    | `requiredBytes` (fit, 262144 tokens) | 55.09 GB | 38.73 GB |
    | Window on this Mac | 262144 | 262144 |
    | Process memory (`top` MEM max / RSS max) | 21.0 GB / 14.3 GB | 20.0 GB / 10.6 GB |
    | Decode, all calls | 31.8 tok/s (4337 tokens) | 24.4 tok/s (3042 tokens) |
    | Decode, the long answer | 33.6 tok/s (3187 tokens) | 27.0 tok/s (2513 tokens) |
    | Prefill of the first prompt (14192 tokens) | 27.6 s | 33.9 s |
    | MTP acceptance | 0.913 | 0.891 |
    | Answers correct | 5 of 5 | 5 of 5 |

    - Quality: the answers are the same in content (391; $0.05 / 5 cents; "marigold" with a tool call; a correct `is_prime` (kv8 has the 6k+-1 form); a correct and complete text on collisions). With 5 prompts, no difference in quality shows.
    - Speed: `kvBits: 8` is slower on this Mac: decode about 20 to 25 % slower, prefill about 23 % slower. One run each, and other Swift builds ran on the Mac at that time, so the numbers have noise.
  timestamp: 2026-11-20T19:55:38.450300+00:00
- actor: claude-code
  id: 01m7xbb973z2x2hwktz944rghn
  text: |-
    Work item 2, the window of the fit estimate (`models` endpoint, `profiles(cwd:)`, this Mac):

    | profile | `requiredBytes` at 262144 tokens | `contextTokens` here |
    |---|---|---|
    | `large` (KV fp16) | 68750487415 | 262144 |
    | `large-kv8` | 52392701815 | 262144 |
    | `medium` (KV fp16) | 55091473637 | 262144 |
    | `medium-kv8` | 38733688037 | 262144 |
    | `small` (kvBits 8) | 19400512451 | 262144 |

    On this Mac (budget 115448725504 bytes) each profile fits at the native window, so `kvBits: 8` gives no larger window here. The window on a target Mac is calculated from these numbers: the required bytes grow linearly with the window (JointFit). The fit counts two KV caches (standard and flash). For Qwen3.8-27B (16 full-attention layers, 4 KV heads, head dim 256) that is 131072 bytes per token in fp16 and 69632 bytes per token at 8 bits (affine groups of 64, 4 bytes for each group). For Qwen3.5-9B (8 full-attention layers) at 8 bits it is 34816 bytes per token. Fixed part = `requiredBytes` - bytes per token x 262144.

    Calculated window (tokens; "no fit" = no window; the minimum window is 32768):

    | budget (assumption) | `large` | `large-kv8` | `medium` | `medium-kv8` | `small` |
    |---|---|---|---|---|---|
    | 16 GB Mac, 2/3 of RAM | no fit | no fit | no fit | no fit | 33879 |
    | 24 GB Mac, 2/3 | no fit | no fit | no fit | no fit | 198361 |
    | 32 GB Mac, 2/3 | no fit | no fit | 16592 | 34846 | 262144 |
    | 32 GB Mac, 3/4 | no fit | no fit | 38437 | 75966 | 262144 |
    | 48 GB Mac, 3/4 | 32531 | 64849 | 136741 | 261009 | 262144 |
    | 64 GB Mac, 3/4 | 130835 | 249892 | 235045 | 262144 | 262144 |

    The budgets of the target Macs are assumptions: `research.md` gives 10922 MiB (2/3) for 16 GB; this 128 GB Mac gives 0.84 of RAM. Verify on a real 32 GB and 48 GB Mac.

    Findings:
    - With KV fp16, `large` on a 48 GB Mac gets 32531 tokens: less than the minimum window of 32768. Thus with the current file, `large` does not fit its own target Mac, and the agent selects `medium`. With `kvBits: 8` the window is 64849.
    - With KV fp16, `medium` on a 32 GB Mac (budget 2/3) gets 16592 tokens: less than the minimum, so the agent selects `small`. With `kvBits: 8` the window is 34846 (more than the minimum).
    - `small` on a 16 GB Mac gets 33879 tokens: just above the minimum (`research.md` said about 49K).
  timestamp: 2026-11-20T20:46:10.659871+00:00
- actor: claude-code
  id: 01m7xbbkvqhp2r6gqer67h8yk4
  text: |-
    PROPOSAL for the user (no profile file is changed; the change needs a go):

    1. `medium.yaml`: add `kvBits: 8`. Evidence: the same quality on the 5 prompts (5 of 5 correct with both), MTP acceptance 0.891 vs 0.913, and a larger window on the target Mac: 34846 vs 16592 tokens on a 32 GB Mac with a budget of 2/3 (with fp16 the window is less than the minimum of 32768, so `medium` does not fit its own target Mac), 75966 vs 38437 with a budget of 3/4. The cost: on this M5 Max (debug build) decode is about 20 to 25 % slower (24.4 vs 31.8 tok/s) and prefill about 23 % slower.
    2. `large.yaml`: add `kvBits: 8` too, if the `large` quality check agrees. The window argument is the same: 64849 vs 32531 tokens on a 48 GB Mac (budget 3/4); with fp16 `large` is less than the minimum on a 48 GB Mac. The quality and speed of `large` are not measured yet (see the next comment).
    3. Before a change, verify the budget (`recommendedMaxWorkingSetSize`) of a real 32 GB and 48 GB Mac: the result depends on it.
  timestamp: 2026-11-20T20:46:21.559603+00:00
- actor: claude-code
  id: 01m7xbbr2q6r8kvmtgtwjnrr79
  text: |-
    Work item 2, part `large`: NOT DONE. The download of the models of `large` does not finish in a usable time.

    - First attempt (12:36 to 13:35): the download went at about 1.4 MB/s, then the network was offline at 13:35 ("The Internet connection appears to be offline", NSURLErrorDomain -1009). The resolve of `large` failed, and `acp-agent acp` ended (a failed resolve at launch ends the process).
    - Second attempt (from 13:56, new debug build with mlx-swift-lm 74e499b): the download makes progress, but at a fixed 160 MB in each 10 minutes (about 0.27 MB/s) since 14:06. On disk: about 19.8 GB of `mlx-community/Qwen3.8-27B-8bit` (5 partial `.incomplete` files of about 3.45 GB); `mlx-community/Qwen3.8-27B-MTP-8bit` not started. About 11 GB remain: about 11 hours at this rate.
    - The run folders and the driver stay in the scratchpad. When the download is complete: run `large`, then `large-kv8`, with the same 5 prompts, and compare as for `medium`.
  timestamp: 2026-11-20T20:46:25.879299+00:00
- actor: claude-code
  id: 01m7xbckezkvcg0g39d662e3yt
  text: |-
    ### implement — stuck
    - evidence: `small` works on the M5 Max after mlx-swift-lm 74e499b (46.0 tok/s, MTP acceptance 0.862, window 262144, 5 of 5 correct). `medium` vs `medium-kv8`: 5 of 5 correct with both, decode 31.8 vs 24.4 tok/s, window on a 32 GB Mac (budget 2/3) 16592 vs 34846. The proposal (`kvBits: 8` for `medium`, and for `large` after its check) is on the card. No file of the repository changed (only the gitignored `Package.resolved` and the debug build).
    - blocker: the `large` models are not downloaded: about 19.8 GB of 30.7 GB, at about 0.27 MB/s (about 11 hours left). The `large` run (download through the product path) still runs in the background.
    - next: when the download is complete, run `large` and `large-kv8` with the 5 prompts (scratchpad driver), and record the comparison. A person gives the go (or not) for the proposal.
  timestamp: 2026-11-20T20:46:53.919814+00:00
- actor: claude-code
  id: 01m7y0pp2eyq3h9xbgryvpy9qj
  text: |-
    The user gave the go for proposal 1 (2026-11-20): add `kvBits: 8` to the bundled `medium` profile. `large` and `small` do not change. `large` stays open (its quality check is not done).

    Implementation (TDD):
    - RED: `ProfileFileTests.mediumIsTheFourBitModelWithItsDrafterAndAnEightBitKVCache` (the old `mediumIsTheFourBitModelWithItsDrafter`, now with `kvCache: .bits8`) failed on the old file.
    - GREEN: `Resources/profiles/medium.yaml` has `kvBits: 8`, and its header comment names the 8-bit KV cache and the reason (a window of more than the minimum of Router on a 32 GB Mac).
    - The `description` of `medium.yaml` does not change. It did not name the KV cache before. (The `description` of `small` names its KV cache. A person can decide if the `medium` description must name it too; the test pins the description.)
    - README: the `medium` row of the profile table names the 8-bit KV cache (`kvBits: 8`).
    - ARCHITECTURE.md and the doc comments of `BundledProfiles.swift` do not list the `kvBits` of a profile, so they do not change.
    - `DefaultProfileChoiceTests` use a stub fit source, and `FitFallbackBudgetTests` assert only "not `large`" and "the same router resolves its choice". Both still describe the right behavior.
    - Note: SwiftPM gives the warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" at each build. It is from the build graph of the dependency, not from a change of this task.
  timestamp: 2026-11-21T02:59:24.366276+00:00
- actor: claude-code
  id: 01m7y0prq20ha4zxad5wj3521j
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACPAgent/Resources/profiles/medium.yaml, Tests/FoundationModelsACPAgentTests/ProfileFileTests.swift, README.md. RED then GREEN on `ProfileFileTests/mediumIs...`. Full root `swift test` after "Build complete!": 2738 tests in 287 suites passed (1 known issue: the existing `withKnownIssue` self-test in HarnessSmokeTests), exit 0. No commit.
    - next: /review. The `large` part of work item 2 stays open (download not complete); the card stays in doing.
  timestamp: 2026-11-21T02:59:27.074652+00:00
- actor: claude-code
  id: 01m7y0san9ce8d0ss1amztb8hp
  text: |-
    ### review — clean
    - evidence: `review sha c23afde~1..c23afde` (HEAD~1..HEAD); 1 file reviewed (ProfileFileTests.swift); 0 findings (0 confirmed, 0 refuted). No validator matched README.md and Sources/FoundationModelsACPAgent/Resources/profiles/medium.yaml, thus the engine did not review them. The card has no earlier review findings.
    - note: By decision of the coordinator, the card stays in doing. Work item 2 (the `large` part) and work item 3 are open while the `large` models download.
    - next: Measure `large` and `large-kv8` when the download is complete. Then record the results on this task.
  timestamp: 2026-11-21T03:00:50.985727+00:00
- actor: claude-code
  id: 01m7y1eykev7xp2n0e70aq1z1q
  text: |-
    `large` download, second attempt: ended at 2026-11-21T03:08:22Z after 7.2 hours.

    - Cause (stderr of the driver run and the telemetry): a network failure at resolve. `FoundationModelsExtras.model.load` of `mlx-community/Qwen3.8-27B-8bit` ended with `NSURLError` -1005 "The network connection was lost." during the download of `model-00004-of-00006.safetensors` from the Hub CDN (`us.aws.cdn.hf.co/xet-bridge-us`). Then `FoundationModelsRouter.resolve` of `large` failed, and `acp-agent acp` ended ("Error: profile "large" did not resolve"). It is not a fault of the model or of the agent code.
    - State on disk: 26 GB of `Qwen3.8-27B-8bit` (1 complete file, 5 partial files of about 4.93 GB). The MTP-8bit drafter is not started.
    - Third attempt started at 03:13Z: the old driver is stopped; debug build "Build complete!" (main at a844424, with c23afde; the binary did not change, the profile files are resources); `acp-agent acp` through the product path, which continues from the partial files.
    - Discovery: one dropped connection in a multi-hour download ends the resolve and the process, and the agent does not try again. A retry of the download in the resolve would make the first launch more robust.
  timestamp: 2026-11-21T03:12:39.534721+00:00
- actor: claude-code
  id: 01m7y2tftp97jdt9jezrq1y30e
  text: |-
    Download retry (FoundationModelsExtras 49c6965) is in the debug build (2026-11-21 03:36Z).

    - `swift package update FoundationModelsExtras`: pin 49c6965. No llama.cpp clone, no new repository.
    - The first build failed: `FoundationModelsRouter/Directory/SessionAddressResolution.swift:164: type 'SessionAddress' has no member 'folder'`. Cause: Extras 41c13c9 removed the `.folder` session address, and the Router pin (95c2141) and the Multitool pin (48581fd) still used it. Router `main` (65cfc07) and Multitool `main` (7fe269e) have the matching change.
    - Thus also `swift package update FoundationModelsRouter` (pin 9b30a4c) and `swift package update FoundationModelsMultitool` (pin d8863fb). No llama.cpp clone, no new repository. The code of this repository does not use the removed case.
    - Debug build: "Build complete!" (12.93 s). Pins now: FoundationModelsExtras 49c6965, FoundationModelsRouter 9b30a4c, FoundationModelsMultitool d8863fb, mlx-swift-lm 74e499b, llama-cpp-swift 6b273d6.
    - The `large` download that runs now (started 03:13Z) uses the old binary, with no retry. Each later `acp-agent` start (a restart after a drop, and the `large` / `large-kv8` measurement runs) uses the new binary with the retry.
  timestamp: 2026-11-21T03:36:26.198361+00:00
- actor: claude-code
  id: 01m7y6yqgakq2s2cr75w11fqrg
  text: |-
    Work item 2, part `large`: DONE (2026-11-21, M5 Max 128 GB, debug build, pins Extras 49c6965 / Router 9b30a4c / Multitool d8863fb / mlx-swift-lm 74e499b). Same 5 prompts, one session for each profile, one run each.

    - Download, third attempt (product path, from the partial files): complete at 04:25:51Z. `Qwen3.8-27B-8bit` 28 GB and `Qwen3.8-27B-MTP-8bit` 452 MB. The third attempt used the old binary (no retry) and had no drop.

    | | `large` (bundled, KV fp16) | `large-kv8` (same models, `kvBits: 8`) |
    |---|---|---|
    | Resolve (models in the cache) | 4420.7 s with the download (standard load 4402.8 s) | 20.6 s (standard 4.7 s, embedding 14.4 s cold) |
    | standard footprint (estimate) | 47.13 GB | 39.08 GB |
    | `requiredBytes` (fit, 262144 tokens) | 68.75 GB | 52.39 GB |
    | Window on this Mac | 262144 | 262144 |
    | Process memory (`top` MEM max / RSS max) | 34.0 GB / 11.8 GB | 32.0 GB / 11.8 GB |
    | Decode, all calls | 37.4 tok/s (6538 tokens) | 35.7 tok/s (3408 tokens) |
    | Decode, the long answer | 40.4 tok/s (4760 tokens) | 38.5 tok/s (2522 tokens) |
    | Prefill of the first prompt (14165 tokens) | 904 s (see the note) | 20.6 s |
    | MTP acceptance | 0.919 | 0.924 |
    | Answers correct | 4 of 5 | 5 of 5 |

    - Quality: both give 391, $0.05, "marigold" (with a tool call) and a correct text of about 250 words on collisions. The `is_prime` of `large` (fp16) has a fault: `i += 2` is indented under `return False`, so it is never done, and the loop does not stop for an odd composite with no small factor (for example 25). The `is_prime` of `large-kv8` is correct. One sample is not a quality difference; it shows that `kvBits: 8` is not worse on these prompts.
    - Speed: `kvBits: 8` decodes about 5 % slower for `large` (for `medium` it was about 20 to 25 %).
    - Note on the 904 s: the first call of `large` came just after the end of the download. The process memory went to 27 GB in about 70 s, then stayed the same for about 14 minutes before the first token. The cause is not known (maybe other GPU work on the Mac, or a cold first pass of the 28 GB of new weights). The second session (`large-kv8`, same weights) did not show it (20.6 s).
    - Window on the target Mac (from the earlier calculation): on a 48 GB Mac (budget 3/4), 32531 tokens with fp16 (less than the minimum of 32768) and 64849 tokens with `kvBits: 8`.
  timestamp: 2026-11-21T04:48:39.434820+00:00
- actor: claude-code
  id: 01m7y6ytff9gtekbsnx5cb2746
  text: |-
    PROPOSAL for the user, `large` (no profile file is changed; the coordinator asks the user):

    `large.yaml`: add `kvBits: 8`.
    - Same quality on the 5 prompts (5 of 5 correct with `kvBits: 8`; the fp16 run had one faulty `is_prime`, a sample fault).
    - MTP acceptance the same (0.924 vs 0.919).
    - A larger window on the target Mac: 64849 vs 32531 tokens on a 48 GB Mac (budget 3/4). With fp16 the window is less than the minimum of 32768, so on a 48 GB Mac the agent does not select `large`, its own target profile. On a 64 GB Mac: 249892 vs 130835.
    - The cost: about 5 % slower decode on this M5 Max (35.7 vs 37.4 tok/s; 38.5 vs 40.4 on the long answer).
    - Before the change, verify the budget (`recommendedMaxWorkingSetSize`) of a real 48 GB Mac: the result depends on it.
  timestamp: 2026-11-21T04:48:42.479395+00:00
- actor: claude-code
  id: 01m7y6za95fa04akc54gdrsa0m
  text: |-
    ### implement — no-change
    - evidence: all work items done. `small` (after mlx-swift-lm 74e499b): 5/5 correct, 46.0 tok/s, MTP 0.862, window 262144. `medium` vs `medium-kv8`: 5/5 vs 5/5, 31.8 vs 24.4 tok/s, MTP 0.913 vs 0.891. `large` vs `large-kv8`: 4/5 vs 5/5, 37.4 vs 35.7 tok/s, MTP 0.919 vs 0.924. Calculated window with `kvBits: 8` on the target Mac: `medium` 34846 vs 16592 (32 GB, budget 2/3), `large` 64849 vs 32531 (48 GB, budget 3/4). The `large` proposal is on the card (no profile file change by this step; `medium` has `kvBits: 8` on main from c23afde). No tracked file of the repository changed in this step; only the gitignored `Package.resolved` (pins Extras 49c6965, Router 9b30a4c, Multitool d8863fb, mlx-swift-lm 74e499b) and the debug build.
    - next: the user decides the `large` proposal. Verify `recommendedMaxWorkingSetSize` of a real 32 GB and 48 GB Mac.
  timestamp: 2026-11-21T04:48:58.661024+00:00
- actor: claude-code
  id: 01m7yq6fg6kccfbdkaqhpbjy91
  text: |-
    The user gave the go (2026-11-21) to add `kvBits: 8` to the bundled `large` profile. BLOCKED before the first edit: a conflict with a documented contract. No file changed.

    The conflict:
    - `large.yaml` is the base of the merge of each profile file (`BundledProfiles.baseKeys`, `ProfileFile.definition(of:name:path:)`: `baseKeys.merging(keys)`). Each key that a file leaves out comes from `large`. With `kvBits: 8` in `large.yaml`, each profile file that has no `kvBits` key gets an 8-bit KV cache.
    - The README and Router's `ProfileDefinition` say: "no key for an unquantized cache" (Router: "A missing `kvBits` key gives an fp16 cache"). The `ProfileFileTests` test "No `kvBits` gives an unquantized KV cache: `large` names none" holds the same contract.
    - The save path breaks: `ProfileStore` saves a profile as `ProfileFile.text(of:)`, and Router's `encode(to:)` writes no `kvBits` key for fp16 (`encodeIfPresent(kvCacheQuantization?.bits)`). Thus a saved fp16 profile reads back with an 8-bit cache. The doc comment of `text(of:)` says the text "decodes back to the profile".
    - A user file then has no documented way to name fp16. (`kvBits: null` can possibly give fp16 through the merge, but it is not documented and `text(of:)` does not write it.)

    A person must choose one:
    - A. `kvBits` does not come from the base: the merge leaves out `kvBits` of `large`. Only the bundled `large` gets 8 bits; a file without `kvBits` stays fp16. The rule "each key that a file leaves out comes from `large`" gets one exception (README, ARCHITECTURE.md, doc comments).
    - B. `kvBits` comes from the base, and fp16 gets a spelling (for example `kvBits: 16` or `kvBits: null`) that `text(of:)` writes. A Router change can be necessary (Router accepts only 8 or 4, or no key), and the README contract changes.
    - C. Another choice.
  timestamp: 2026-11-21T09:32:30.598296+00:00
- actor: claude-code
  id: 01m7yq6j1dp813yr7s872keq0p
  text: |-
    ### implement — stuck
    - evidence: no file changed. `large.yaml` is the merge base of each profile file (`ProfileFile.definition(of:name:path:)`, `BundledProfiles.baseKeys`), so `kvBits: 8` in it gives 8 bits to each file with no `kvBits` key. This fights the documented contract "no key for an unquantized cache" (README, Router `ProfileDefinition`, ProfileFileTests), and breaks the round trip of a saved fp16 profile (`ProfileFile.text(of:)` writes no `kvBits` for fp16).
    - next: a person chooses option A (do not inherit `kvBits` from the base), B (inherit, plus a written spelling for fp16), or C. Then implement with TDD.
  timestamp: 2026-11-21T09:32:33.197961+00:00
- actor: claude-code
  id: 01m7yx75hahk97kn7ctxkardj0
  text: |-
    ### implement — stuck
    - evidence: no file changed. The `kvBits: 8` change of `large.yaml` waits for ^f4z8wj9 (defaults from the profile config type in code, not from `large.yaml`). ^f4z8wj9 is stuck on a question for the user: a code default for `standard` (and `flash`, `embedding`, `description`); see the comments of ^f4z8wj9.
    - next: when the user answers, implement ^f4z8wj9, then add `kvBits: 8` to `large.yaml` with TDD.
  timestamp: 2026-11-21T11:17:44.618222+00:00
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: doing
position_ordinal: '8180'
title: 'ACPA-23 (D203): real Mac check of small (MTP, kvBits 8), and measure kvBits 8 for large and medium — downloads approved'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, part 1 (the measurement) and the last test. Facts: `research.md` in the same folder.

## Dependency

^56r9vp9 (the three bundled profiles).

## Downloads

- The user removed the download gate (2026-11-20). The task downloads the models of each profile through the product's own path (Router's profile resolution at the first `session/new`), with no question to the user: `small` is about 9.4 GB, `medium` about 19.3 GB, `large` about 33.9 GB (with the embedding and decision models).
- Do not change `kvBits` of `large` or `medium` without a go from the user. Propose the change only.

## Work

- [x] 1. On a real Mac: a session with the `small` profile loads and answers with the MTP drafter and `kvBits: 8`. `research.md` says that this path is not verified. Report the result (load time, memory, window, tokens per second, drafter acceptance if available) to the user. (Done on an M5 Max after the fix of ^xgqst2y: see the comments.)
- [x] 2. Measure `kvBits: 8` for `large` and `medium`: quality on the same prompts, the window that the fit estimate gives, and the speed. If `kvBits: 8` gives the same quality and a larger window, propose the change to the user. Change the profile files only with a go.
  - [x] `medium` and `medium-kv8`: quality, window, speed. The proposal is on the card.
  - [x] The fit window of all profiles, and the calculated window on the target Macs.
  - [x] `large` and `large-kv8`: quality and speed. The proposal is on the card.
- [x] 3. Record the results on this task.

## Tests

- No unit test. The result is a record on this task and a report to the user. #d203 #profiles #acpa-23