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

- `DotfolderName.swift` — a validated wrapper for the frontend-supplied `<name>`. Throw at construction for: empty, a `/` or `\` or any path separator, `.` or `..`, or a leading `.` (§2.1).

- `AgentConfiguration.swift` — the `Codable` schema whose property defaults ARE the builtin defaults (§2.2 layer 1, with no shipped config.yaml). Sections: `profile`, `tools` (decoded in a later task), `recording`, `transcripts` (default `location: project`), `compaction`, and `sandbox` (decoded in the codec task). There is no `instructions` section and no context-size knob (§2.4).

  **Two corrections to the old task text:**
  - **There is no `permissions` section.** Multitool deleted its permission layer on 2026-08-24 and the user chose the sandbox-only path. The `sandbox` section replaces it.
  - **`recording.level` accepts only `off` and `full`.** Router's `RecordingLevel` has exactly those two cases. There is no `metadata` level. Default to `full`. Reject any other value with a message naming the two valid ones.

- `ConfigurationLoader.swift` — build Extras' `DotfolderStack(name:workingDirectory:userDirectory:environment:)`, injectable for tests, with no `defaultsDirectory`. Load `config.yaml` through Extras' `LayeredYAMLDocument`; the builtin layer renders trusted and the user and project layers render untrusted. Decode the merged value tree. The user layer is `~/.config/<name>/`, honoring an absolute `$XDG_CONFIG_HOME`. Resolve the project layer `<cwd>/.<name>/` per session (§2.2).

- An unknown top-level section gives a logged warning. An unknown key inside a known section gives an error (§2.4).

- [ ] `DotfolderName` validation
- [ ] `AgentConfiguration` schema with in-code defaults, and no `permissions` section
- [ ] `recording.level` limited to `off` and `full`
- [ ] Layered loading through `DotfolderStack` and `LayeredYAMLDocument`
- [ ] Unknown-section warning and unknown-key error behavior

## Acceptance Criteria
- [ ] Invalid names (`""`, `"a/b"`, `".."`, `".x"`, `"a\\b"`) each throw at construction
- [ ] With no config files, the decoded configuration equals the in-code defaults
- [ ] A project-layer key overrides the same user-layer key, at key level
- [ ] `$XDG_CONFIG_HOME` is honored only when set and absolute; otherwise `~/.config/<name>/`
- [ ] Two loaders with different `workingDirectory` see different project layers
- [ ] `recording: {level: metadata}` gives an error naming `off` and `full`
- [ ] A `permissions:` section gives the unknown-section warning, not a decode

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/DotfolderNameTests.swift` — the validation matrix
- [ ] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` — temp-dir user and project layers through an injected `userDirectory` and `environment`; defaults, override, XDG, the unknown-section warning, the unknown-key error, and the recording-level cases
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.