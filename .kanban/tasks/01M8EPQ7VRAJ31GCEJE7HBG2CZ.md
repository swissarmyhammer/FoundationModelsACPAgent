---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8f0w2r56rtjwqazng6ws6xm
  text: |-
    ### Goal met for one task each — 2026-11-27
    - cluster2i: Inkling 2 Mini 4bit (profile inkling24, MTP dropped), build cluster-0b560b5 (Router f3624eb9, Cluster 0b560b5 worker cache cap). django__django-13447 RESOLVED, 6878 s, 360 calls, 108k tokens out, 60.4 tok/s; 0 prompt-cache hits (34k uncached/call, TTFT 67 min) — fixed later by Router ^n98hpry.
    - cluster3q: Qwen 27B 8bit (profile q8kv8, run with fp16 KV and no drafter under policy always), build cluster-2b88ac4 (Router 2b88ac48, Cluster 0b560b5). RESOLVED, 2358 s, 126 calls, 87k out, 43.2 tok/s, 110/126 cache hits (1.7k uncached/call).
    - Workers 11–25 GB on each Mac, no member loss in either run (so the ^hvygt9p fallback and ^sdqenwv report were not exercised).
    - vs one Mac on 13447: Inkling 4bit+MTP 22 min (inkling24); Qwen q8kv8 28 min. Cluster is still slower: no MTP (mlx-swift-lm ^rgzk56j) and no KV8 (^2ry6yz7); Inkling ran before the cache fix.
    Next: rerun Inkling on cluster-2b88ac4 (cache fix), then the mlx-swift-lm cards for speed.
  timestamp: 2026-11-27T17:29:26.533407+00:00
position_column: done
position_ordinal: ffffffc280
title: 'Goal: one SWE-bench task runs to a patch on the 2-Mac cluster, with Qwen 27B and with Inkling 2 Mini'
---
## Goal
django__django-13447 resolves on the m5u1 + m5u2 cluster (policy always) with Qwen3.8 27B and with Inkling 2 Mini. Then compare time and tokens with the one-Mac runs.

## First attempt, 2026-11-27 (build bench/bin/cluster-40d7f3a, `cluster:` config ^j1vfmkf)
- cluster1i (Inkling 4bit + oQ4e MTP, profile inkling24): EMPTY in 4.4 min. Head rank-0 worker died under memory pressure at a 54k prefill. Then the open sessions failed with ClusterModelError, with no fallback.
- cluster1q (Qwen 27B 8bit + MTP, kvBits 8, profile q8kv8): EMPTY in 1.1 min. First call failed: unsupported(cacheConfiguration).
- Clustered Inkling ran with no MTP: 67 tok/s, against ~105 tok/s on one Mac with MTP.
- Fixed on the way: Cluster doctor hostKey case bug (FoundationModelsCluster bef833f).

## Blockers (other boards)
- Router ^xbx4sg4: cluster sizing leaves the head no room (OOM).
- Router ^hvygt9p: a lost cluster mid-session must re-resolve locally and retry.
- Router ^g7qwhh1: honor kvBits and the drafter when clustered, or don't cluster that profile.
- mlx-swift-lm ^2ry6yz7: clustered kvBits.
- mlx-swift-lm ^rgzk56j: clustered speculative decoding (MTP).
- FoundationModelsCluster ^sdqenwv: a dead worker reports the real cause.
- ACPAgent ^8mr8xt2: the fit source of `config show` / `doctor` is not clustered.

## Retest plan
1. After xbx4sg4 + hvygt9p: rerun cluster1i (Inkling, profile inkling24). Expect a patch, even if MTP is off.
2. After g7qwhh1: rerun Qwen with the hint24 profile (Qwen 4bit + MTP, fp16 KV), then q8kv8 once 2ry6yz7 lands.
3. After rgzk56j: rerun both and compare tok/s with the one-Mac runs (inkling8, q8kv8).
Each rerun: a new frozen build in bench/bin, worker rebuilt from the same mlx-swift-lm revision, and the bench model stated before launch. #cluster #bench