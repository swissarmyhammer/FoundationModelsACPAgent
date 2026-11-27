---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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