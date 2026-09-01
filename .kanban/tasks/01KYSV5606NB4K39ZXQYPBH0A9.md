---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1f2pcyy8c8h09gbsd7pknn2
  text: |-
    ### research — what the upstream surface gives

    - Extras `DotfolderStack.init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)`. No `defaultsDirectory` gives the layers `[user, project]`. A `nil` `userDirectory` derives `$XDG_CONFIG_HOME/<name>/` only when the injected environment holds an absolute value, and `~/.config/<name>/` if not. The init has a `precondition` on the name, so `DotfolderName` must reject a bad name before the stack is built.
    - Extras `LayeredYAMLDocument.load(_:from:engine:context:)` renders the `defaults` layer trusted and the `user`/`project` layers untrusted, merges by key (scalars and arrays replace), and gives `root: YAMLValue`. `YAMLValue.decoded(as:)` goes through Yams `YAMLDecoder`, which ignores unknown keys. So the unknown-section warning and the unknown-key error come from a walk of `root` against the schema's `CodingKeys` before the decode.
    - Extras `TemplateEngine(partials:)` and `TemplateContext()` are the only public constructors.
    - Router `RecordingLevel` is `off`/`full`, `String`-backed, `CaseIterable`. Router `ModelRef` decodes from a string. Router `TokenBudget` has `trigger` (0.80), `target` (0.50), `hardCeiling`, `toolOutputLimit`; `limit` comes from the model, so the `compaction` section carries the four fractions and caps, not a limit.
    - Plan §2.4: `tools` and `sandbox` are sections of the schema, but their bodies decode in task ^jwr5jq4 (the codec task). This task keeps them as open sections: present, not key-checked, no body decoded.
    - Plan §4.1: `transcripts.location` is `project` (default), `home`, or an absolute path.
    - Router and Multitool log through `os.Logger(subsystem:category:)`. The loader logs each unknown-section warning that way and also returns it, so a test can assert it.
  timestamp: 2026-09-01T18:11:24.766590+00:00
- actor: claude-code
  id: 01m1f2zpmeaj4rdf64qbf07whb
  text: |-
    ### progress — implementation landed, tests green

    Files:
    - `Sources/FoundationModelsACPAgent/Configuration/DotfolderName.swift` — `DotfolderName` and `DotfolderNameError` (empty, path separator, `.`/`..`, leading dot).
    - `Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift` — the schema with in-code defaults; `KeyCheckedSection` derives each section's known keys from its `CodingKeys`; `tools` and `sandbox` are open sections for the codec task ^r5jq4h5.
    - `Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift` — the stack, `LayeredYAMLDocument` load, the schema walk (unknown section → warning, logged through `os.Logger` and returned; unknown key → `ConfigurationError.unknownKey`), the decode.
    - `Tests/FoundationModelsACPAgentTests/DotfolderNameTests.swift`, `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`.

    `swift test`: 25 tests in 3 suites passed, no compiler warning.

    Discovery: YAML 1.1 (Yams' default resolver) reads the bare word `off` as the boolean `false`, and Extras hands it on as the string `"false"`. `RecordingConfiguration` maps that one string to `.off`, so `recording: {level: off}` works as the plan writes it. Every other non-level value is an error that names `off` and `full`.

    The earlier research comment names the codec task as ^jwr5jq4; the correct short id is ^r5jq4h5.
  timestamp: 2026-09-01T18:16:29.582664+00:00
- actor: claude-code
  id: 01m1f3462fnx5bay8qagqx0a1m
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Configuration/DotfolderName.swift, Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift, Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift, Tests/FoundationModelsACPAgentTests/DotfolderNameTests.swift, Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift. `swift test`: 25 tests in 3 suites passed, 0 compiler warnings (the one `missing creator for mutated node` line is the pre-existing mlx bundle build-system notice, present before this change).
    - next: test, commit, review
  timestamp: 2026-09-01T18:18:56.463265+00:00
- actor: claude-code
  id: 01m1f34nxv9gz3f4zgza451z4p
  text: |-
    ### test — green
    - evidence: `swift test` — 25 tests in 3 suites passed, 0 failed, 0 skipped; no compiler warning in package sources; no disabled test
    - next: commit
  timestamp: 2026-09-01T18:19:12.699670+00:00
depends_on:
- 01KYSV4RJGFQ3HYG7J5C3P8H6D
position_column: doing
position_ordinal: '80'
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

- [x] `DotfolderName` validation
- [x] `AgentConfiguration` schema with in-code defaults, and no `permissions` section
- [x] `recording.level` limited to `off` and `full`
- [x] Layered loading through `DotfolderStack` and `LayeredYAMLDocument`
- [x] Unknown-section warning and unknown-key error behavior

## Acceptance Criteria
- [x] Invalid names (`""`, `"a/b"`, `".."`, `".x"`, `"a\\b"`) each throw at construction
- [x] With no config files, the decoded configuration equals the in-code defaults
- [x] A project-layer key overrides the same user-layer key, at key level
- [x] `$XDG_CONFIG_HOME` is honored only when set and absolute; otherwise `~/.config/<name>/`
- [x] Two loaders with different `workingDirectory` see different project layers
- [x] `recording: {level: metadata}` gives an error naming `off` and `full`
- [x] A `permissions:` section gives the unknown-section warning, not a decode

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/DotfolderNameTests.swift` — the validation matrix
- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` — temp-dir user and project layers through an injected `userDirectory` and `environment`; defaults, override, XDG, the unknown-section warning, the unknown-key error, and the recording-level cases
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.