---
assignees:
- claude-code
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