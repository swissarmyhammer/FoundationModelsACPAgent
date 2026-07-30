---
assignees:
- claude-code
depends_on:
- 01KYSV4RJGFQ3HYG7J5C3P8H6D
position_column: todo
position_ordinal: '8180'
title: 'Configuration: dotfolder name validation, stack construction, layered config.yaml loading'
---
## What
Plan.md §2.1–§2.4. Create `Sources/FoundationModelsACPAgent/Configuration/`:

- `DotfolderName.swift` — a validated wrapper for the frontend-supplied `<name>`. Hard error at construction (throwing init) for: empty, contains `/`, `\`, or any path separator, equals `.` or `..`, or starts with `.` (§2.1).
- `AgentConfiguration.swift` — the `Codable` schema whose property defaults ARE the builtin defaults (§2.2 layer 1, no shipped config.yaml): sections `profile`, `tools` (decoded in a later task), `permissions`, `recording` (default `level: full`), `transcripts` (default `location: project`), `compaction`. No `instructions` section, no context-size knob (§2.4).
- `ConfigurationLoader.swift` — builds Extras' `DotfolderStack(name:workingDirectory:userDirectory:environment:)` (injectable for tests, no `defaultsDirectory`), loads `config.yaml` via Extras' `LayeredYAMLDocument` (builtin renders trusted; user/project layers untrusted), decodes the merged value tree. User layer `~/.config/<name>/` honoring absolute `$XDG_CONFIG_HOME`; project layer `<cwd>/.<name>/` resolved **per session** (§2.2).
- Unknown top-level section → logged warning; unknown key inside a known section → error (§2.4).

- [ ] `DotfolderName` validation
- [ ] `AgentConfiguration` schema with in-code defaults
- [ ] Layered loading through `DotfolderStack` + `LayeredYAMLDocument`
- [ ] Unknown-section warning / unknown-key error behavior

## Acceptance Criteria
- [ ] Invalid names (`""`, `"a/b"`, `".."`, `".x"`, `"a\\b"`) each throw at construction
- [ ] No config files at all → decoded configuration equals the in-code defaults
- [ ] A project-layer key overrides the same user-layer key (key-level merge)
- [ ] `$XDG_CONFIG_HOME` respected only when set and absolute; else `~/.config/<name>/`
- [ ] Two loaders with different `workingDirectory` see different project layers

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/DotfolderNameTests.swift` — the validation matrix
- [ ] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` — temp-dir user/project layers via injected `userDirectory`/`environment`; defaults, override, XDG, unknown-section warning, unknown-key error
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.