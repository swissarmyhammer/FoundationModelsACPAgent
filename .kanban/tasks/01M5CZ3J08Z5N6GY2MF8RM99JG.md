---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d2q2z3np34w4pwq7190mc7
  text: |-
    Research done.
    - `MCPServerConfiguration.Transport` holds `[String: String]` for env and headers. Callers that build it: `MCPComposition.normalize` (client servers), and tests in MCPCompositionTests, ToolSectionCodecTests, BuiltinCommandsTests, ToolsDoctorTests, AgentMetricsTests.
    - Plan: the values become `ConfiguredSecret`. Decode reads `keychain:<name>` as a reference. A client server of `session/new` wraps each value as a literal, so its behavior does not change.
    - The lookup logic is `WebToolOptions.value(of:keyPath:from:warnings:)` (private). It moves to `ConfiguredSecret.resolved(through:keyPath:warnings:)`, and the web pass and the new mcp pass both call it. No copy.
    - Warning key path: `tools.mcp.<server>.env.<key>` or `tools.mcp.<server>.headers.<key>`. It names the server, the key and the reference.
    - Encode: env literal is written plain (as now). Header literal uses the ConfiguredSecret form (`<redacted>`). A reference is `keychain:<name>` in each form. The `omitted` form (`/config export`, `config init`) writes no literal header, the same contract as `tools.web.apiKeys`. Note: the mcp list replaces lower lists, thus an export drops a literal header from the effective configuration. The export note tells the operator to use a `keychain:` reference.
    - Test seams: `MCPComposition.envVariables` and a new internal `sessionConfiguration(headers:)` for `httpAdditionalHeaders`.
  timestamp: 2026-10-20T16:36:05.731040+00:00
- actor: claude-code
  id: 01m5d35xak25p717zph6hdxyvm
  text: |-
    Implementation landed.
    - `MCPServerConfiguration.Transport` env and headers are now `[String: ConfiguredSecret]`. `MCPServerConfiguration.resolvingSecrets` and `MCPToolSection.resolvingSecrets` resolve each reference; `ConfigurationLoader.resolvingSecrets` runs the web pass, then the mcp pass.
    - The shared lookup is `ConfiguredSecret.resolved(through:keyPath:warnings:)` (do/catch, no `try?`). `WebToolOptions.resolvingSecrets` now calls it; its private copy is gone. New shared helpers: `Encoder.writtenSecrets(_:)` (the web encode and the header encode both call it), `Dictionary.resolvedValues`, `Dictionary.resolvingSecrets(through:section:warnings:)`, `ConfiguredSecret.plainForm` (env encode).
    - `MCPComposition.envVariables` (now internal) and the new `MCPComposition.sessionConfiguration(headers:)` use the resolved values. A reference with no value gives no pair and no header.
    - Decision on a gap of the card: `/config export` and `config init` (the `omitted` form) write no literal header, the same contract as `tools.web.apiKeys`. The mcp list replaces lower lists, thus after an export a literal header is not in force. The export note now says "no literal tools.mcp headers value", and the `SecretForm.omitted` doc says it. If the user wants the literal header in the export file, this is the place to change.
    - Discovery: a `/config` wire test cannot use a config http MCP server, because a config server that cannot connect fails `session/new`. The `/config` header redaction test calls `BuiltinCommands.renderConfiguration` (now internal) directly; the wire tests use a stdio `mcp-test-server` with an env reference.
    - TelemetryContentSafetyTests now gives the loopback server an env `keychain:` reference; the value is forbidden in every record.
    - README and `builtin.config.yaml` document the env and headers references.
  timestamp: 2026-10-20T16:44:11.475082+00:00
- actor: claude-code
  id: 01m5d360d1favx0cja7n73qar0
  text: |-
    ### implement — changed
    - evidence: `swift test` 1037 tests in 115 suites passed, 0 failures, 1 known issue (pre-existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. 17 files: Sources/FoundationModelsACPAgent/{Configuration/ConfiguredSecret.swift, Configuration/ToolSectionCodec.swift, Configuration/ConfigurationLoader.swift, Configuration/ConfigurationYAML.swift, Commands/BuiltinCommands.swift, Tools/MCPComposition.swift, Resources/builtin.config.yaml}, README.md, Tests/FoundationModelsACPAgentTests/{MCPSecretReferenceTests.swift (new, 13 tests), BuiltinCommandsTests.swift, ConfigShowTests.swift, TelemetryContentSafetyTests.swift, MCPCompositionTests.swift, ToolSectionCodecTests.swift}.
    - next: /review
  timestamp: 2026-10-20T16:44:14.625975+00:00
- actor: claude-code
  id: 01m5d38xj1t5xtcnajnv3k9dv8
  text: |-
    ### test — green
    - evidence: touched the changed sources and tests, then `swift test`: 1037 tests in 115 suites passed, 0 failures, 1 known issue (accepted withKnownIssue in HarnessSmokeTests), 0 compiler warnings. `swift build --build-tests --package-path IntegrationTests`: Build complete, 0 compiler warnings. The only warning in both runs is the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle.
    - next: /review
  timestamp: 2026-10-20T16:45:50.017928+00:00
depends_on:
- 01M5CZ2K9R4436W0DCWZD0PY0N
position_column: doing
position_ordinal: '80'
title: 'ACPA-18: MCP server env and header values can be keychain: references'
---
## What
ACPA-18 and D98(d): the tokens of the MCP servers are secrets in the Keychain too. Now `MCPServerConfiguration.Transport` holds `.stdio(env: [String: String])` and `.http(headers: [String: String])` (`ToolSectionCodec.swift:552-627`), and `encode` writes them verbatim (lines 619-625). So `config show`, `config show --json`, `/config` and `/config export` print MCP tokens in clear text.

Do this:
- A value of `env` or `headers` can be `keychain:<name>`. At load, resolve it with the `SecretStore`, the same as `ConfiguredSecret` of card ^zd0py0n. With no item: a `ConfigurationWarning` names the server, the key and the reference; leave that one variable or header out, and keep the server.
- Store each value as a `ConfiguredSecret` (or a small type that holds a reference or a literal), so that encoding writes `keychain:<name>` for a reference.
- A literal `headers` value is redacted in `config show` and `/config` (headers carry tokens). A literal `env` value stays as now, because env also holds values that are not secrets (for example `PATH`); `ToolsDoctor` already warns about secrets in env (`ToolsDoctor.swift:129-133`).
- `MCPComposition` (`MCPComposition.swift:461-467`, line 756) uses the resolved values.
- The client-supplied MCP servers of `session/new` do not change.

## Acceptance Criteria
- [x] `Authorization: keychain:github-mcp-token` in `headers` sends the value of the item to the server.
- [x] `GITHUB_TOKEN: keychain:github-token` in `env` gives the value to the child process.
- [x] `config show` and `/config` show the references, and redact literal header values.
- [x] A reference with no item gives a warning that names only the reference.

## Tests
- [x] Load and encode tests with `InMemorySecretStore` for env and headers.
- [x] A test that the resolved header reaches `httpAdditionalHeaders`.
- [x] A test that no value is in the `config show` output or a captured log.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18