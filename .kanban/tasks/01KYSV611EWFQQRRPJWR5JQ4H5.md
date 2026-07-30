---
assignees:
- claude-code
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
position_column: todo
position_ordinal: '8380'
title: 'Configuration: tool-section codec, permissions modes, denial union'
---
## What
Plan.md §2.5, §11.2, §11.7 (config side only — the wire method is a later task). In `Sources/FoundationModelsACPAgent/Configuration/`:

- `ToolSectionCodec.swift` — the enable/disable rule for `tools:`. Per tool key: absent / `{}` / null / `true` → on with defaults; scalar `false` → off (checked before body decode); a mapping body decodes as **that tool package's own option type** (unknown key in a body = error). No `tools: false` global switch, no `only:` allowlist. `mcp:` is the one list-bodied entry: omitted → on with no servers; `mcp: [...]` → those servers; `mcp: false` → fully off including refusing client-supplied servers (that refusal enforced in the MCP task).
- Shell policy composition (§2.5): decode `tools.shell` as Shelltool's option type, then compose `ShellPolicy(rules: ShellPolicy.builtinRules.merged(with: configured), decisions: store)`. **Denials union across layers** (builtin + user + project all apply — never overridden); `allow`/`ask` follow normal nearest-wins.
- `PermissionsConfig.swift` (§11.7): `permissions:` decodes `"*"` (default when absent) / `policy` / `ask` / mapping form `{shell: policy, mcp: ask}` (unmentioned tool → `"*"`). Layering: a layer may only move a tool **stricter** (`"*"` → `policy` → `ask`), never looser.

- [ ] Per-tool scalar-false-then-body codec
- [ ] `mcp:` list decoding with the three states
- [ ] Shell denial union across layers + composed `ShellPolicy` value
- [ ] `permissions` decode with stricter-only layering

## Acceptance Criteria
- [ ] The five shapes of §11.2's table each decode to the documented meaning
- [ ] Unknown key inside `tools.shell:` body → error; unknown top-level tool section → warning only
- [ ] Project-layer `deny` adds to, never replaces, user-layer and builtin denials
- [ ] User `permissions: ask` + project `permissions: "*"` resolves to `ask`; the reverse resolves to `ask` too

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ToolSectionCodecTests.swift` — the §11.2 five-shape matrix, mcp tri-state, unknown-key error
- [ ] `Tests/FoundationModelsACPAgentTests/PermissionsConfigTests.swift` — mode parsing, per-tool mapping, stricter-only layering both directions
- [ ] `Tests/FoundationModelsACPAgentTests/ShellPolicyCompositionTests.swift` — denial union across two temp-dir layers; composed policy still contains builtin denials
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.