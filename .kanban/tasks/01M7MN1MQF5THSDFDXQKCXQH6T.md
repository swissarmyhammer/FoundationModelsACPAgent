---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7mpppq3eyz1q1akar1cce3r
  text: |-
    Part 1 pushed as 7d66b77 (on the ACPA-21 preset shape). Part 2 waits on Router's push of ^2fet0gs. Its local f81ab2a2 is 27 commits behind origin and lacks the `offline:` init, and I asked Router to put `kvCacheQuantization:` on that init too.
    Plan: `ComposedAgent.compose` already has the configuration when it calls `makeRouter`, so pass `configuration.profile.kvBits` → `makeRouter` → `makeLiveModelLoader(…, kvCacheQuantization:)`, mapping 8→.bits8, 4→.bits4, nil→nil. Tests in ModelCacheDirectoryTests: assert `loader.kvCacheQuantization` (public on LiveModelLoader) for 8, 4 and nil. The setting is read at launch, like preset.
  timestamp: 2026-11-17T12:11:29.379006+00:00
position_column: todo
position_ordinal: '8280'
title: 'profile.kvBits: KV-cache bits for every model (8 or 4, absent = unquantized)'
---
Router asks (^2fet0gs): a config key `profile.kvBits` that sets the KV-cache quantization of every model, like GenerateParameters(kvBits: 8). Chain: mlx-swift-lm → Extras MLXModelLoader → Router `KVCacheQuantization { bits8, bits4 }` + `LiveModelLoader.init(..., kvCacheQuantization:)` → this agent.

Part 1 (now):
- [ ] `kvBits: Int?` on ProfileConfiguration; absent / null = unquantized.
- [ ] Any value other than 4 or 8 is a settings error naming the valid values.
- [ ] `acp-agent config show` lists `kvBits: null` by default.
- [ ] README documents the key.
- [ ] Tests first: default nil, project 8 decodes, 4 decodes, 6 rejected, config show line.

Part 2 (waits on Router sha):
- [ ] Map kvBits → KVCacheQuantization and pass it through `ComposedAgent.makeLiveModelLoader`.

#config