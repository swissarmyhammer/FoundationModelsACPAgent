---
depends_on:
- 01KY7ECSJGTV23JVX3D4AXZGQM
position_column: todo
position_ordinal: '8180'
title: 'AgentConfiguration: schema + codec over Extras'' LayeredYAMLDocument'
---
Plan §4. Codable+Sendable+Equatable, constructible in tests with zero file I/O. **No `instructions:` section — deleted 2026-07-28** (the system prompt is a stacked markdown `Instructions.md`, not YAML — see §6.0 and task gbnxktn; its presence in a config file must warn as an unknown section). Sections: profile (standard/flash/embedding candidate lists → Router ProfileDefinition, ModelRef org/repo@rev), tools (OPTIONAL — see below — built-in sections + mcp list; each mcp entry carries a required `type` discriminator plus name and either command/args/env for stdio or url/headers for http; v2 removed sse), recording (level → RecordingLevel), transcripts (home|project|absolute), compaction (prompt/budget overrides). Loading: Extras' LayeredYAMLDocument (SHIPPED — Extras rqxez38) over DotfolderStack; unknown top-level keys warn (forward compat for tool sections), unknown nested keys error (typo protection); malformed layer = hard error naming file+line. **No shipped defaults directory (removed 2026-07-28)** — `AgentConfiguration`'s own property defaults ARE the defaults; nothing is materialized on first run and there is no `<NAME>_DEFAULTS_DIR`. Pass no `defaultsDirectory` to `DotfolderStack`. Hermetic fixture tests, userDirectory/environment injection, never the real home.

## Added 2026-07-28: `tools:` is optional and absence-enables

The `tools:` section is **optional**, and omitting it — or omitting any individual tool within it — **enables that tool with its own defaults**. This reverses the earlier "presence enables" rule, which had the fatal property that a user with no config file got an agent with no tools.

Codec requirements that follow:

- A missing `tools:` key must decode to *all built-ins enabled*, not to an empty roster. This is the one place where absent and empty must NOT be equivalent.
- Each tool entry is a **three-way**: scalar `false` (disabled), scalar `true`/`null`/`{}` (enabled with defaults), or a mapping (enabled, decoded as that tool package's own option type). Check the scalar case before attempting the mapping decode.
- `false` must stay OUTSIDE the body — an `enabled:` key inside would collide with the rule that unknown keys inside a known section are errors, forcing every tool package's option struct to carry a flag only this layer cares about.
- `mcp:` is a list, so its three-way differs: omitted/`[]` = enabled with no local servers (client-supplied ACP servers still connect), `false` = MCP off including refusal of client-supplied servers.
- Layering is ordinary key-level override: a user layer may disable what defaults enable; a project layer may re-enable with `shell: {}`. Nearest layer mentioning the tool wins.
- The shipped defaults `config.yaml` should therefore NOT carry a `tools:` section — absence is the rule, and duplicating it in the defaults file would create a second place to keep in sync.

Tests: no `tools:` key → full roster; `tools: {}` → full roster; `shell: false` → roster minus shell with everything else intact; `shell: true` → enabled, not an error; a project layer re-enabling a user-layer disable; `mcp: false` vs `mcp: []` producing different client-server behavior.

## Added 2026-07-28: `<name>` validation, and serializing back out

**`<name>` is a construction parameter** supplied by the frontend and it becomes a path component, so validate it at construction as a hard error, not a warning: reject empty, anything containing `/` or `\` or a platform path separator, `.`, `..`, and any name beginning with `.` (the project layer adds the dot; callers never supply it). An unvalidated name turns config export into a write-to-arbitrary-path primitive.

**Exact locations** (note the deliberate dot asymmetry — each follows its own directory's convention):

| Layer | Path | Dot |
|---|---|---|
| user | `$XDG_CONFIG_HOME/<name>/` if set and absolute, else `~/.config/<name>/` | no — `~/.config` is already hidden |
| project | `<session cwd>/.<name>/` | yes — it sits beside source at a repo root |

The project layer resolves against the **agent's session working directory** (ACP `session/new(cwd)`), not the process cwd — one process serves many sessions in different repos, so this is per-session and two concurrent sessions legitimately see different project config.

**Serialization is now part of this task's surface**, because defaults living in code means a default you cannot see is one you cannot change. `AgentConfiguration` needs a commented-YAML emitter backing `/config` and `/config export home|project` (§4). Requirements:

- Emit the **effective merged** config (code defaults + user + project) — that is what "my current config" means to the asker.
- Annotate each key with its origin using `LayeredYAMLDocument`'s existing per-key source tracking (`# default` vs `# from ~/.config/<name>/config.yaml`), and state in the header that the written file now pins those values. This is the mitigation for the real hazard: exporting a fully-resolved config to the project layer freezes every inherited value, so later default improvements stop reaching that repo. The annotations let a user delete the `# default` keys with confidence.
- Yams emits values, not prose, so comments must be attached deliberately.

Two tests matter more than the emitter's implementation, because the failure mode is **drift** — a schema key the emitter forgets, silently missing from every exported file thereafter:

- [ ] **Round-trip**: export → decode the emitted YAML → equals the original config. (Truthful.)
- [ ] **Total coverage**: every `CodingKey` in the schema appears in the emitted output. (Complete — this is the one that catches drift; without it round-trip passes happily on a file missing half the schema.)