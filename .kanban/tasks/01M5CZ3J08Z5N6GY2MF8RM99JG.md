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
- actor: claude-code
  id: 01m5d3fsjcnxvc0smja95jyzqx
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (94aa08f): 2 findings (2 confirmed, 3 refuted) — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:455, Tests/FoundationModelsACPAgentTests/MCPSecretReferenceTests.swift:361
    - next: Correct the two open items in "Review Findings (2026-10-20 11:46)". Then do the review again.
  timestamp: 2026-10-20T16:49:35.308460+00:00
- actor: wballard
  id: 01m5d3g7hbpmcg6z79veavkfsd
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 14 files
    - test: green — swift test 1037 passed; IntegrationTests builds
    - commit: 94aa08f
    - review: findings — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:455, Tests/FoundationModelsACPAgentTests/MCPSecretReferenceTests.swift:361
  timestamp: 2026-10-20T16:49:49.611218+00:00
- actor: claude-code
  id: 01m5d3md41cdgq7msv4bdpt4gf
  text: |-
    Review findings corrected.
    - reuse/reuse: new private generic `MCPComposition.literalSecrets(_:name:value:)` takes the wire pairs and two key paths (`EnvVariable` and `HTTPHeader` of FoundationModelsACP share no protocol, thus key paths and no new protocol). Both cases of `normalize` call it. The last-repeated-name rule is now in one place. Other changed files: `MCPServerConfiguration.resolvingSecrets` already calls the shared `Dictionary.resolvingSecrets` helper for each case; no other copy found.
    - invariant-propagation: `noLogRecordHoldsAValue` now does two loads under the telemetry capture. The first load reads `storeWithItems` and checks that the header and the env reference both get their value. The second load reads an empty store, thus the records hold one warning for each key path: header, then env. The assertion on the warning key paths stays. The other tests of MCPSecretReferenceTests that forbid a value (redacted, omitted, JSON forms) already load with `storeWithItems`; no other vacuous check found.
  timestamp: 2026-10-20T16:52:06.401464+00:00
- actor: claude-code
  id: 01m5d3mfgdm73xxh0tc54vq93n
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift, Tests/FoundationModelsACPAgentTests/MCPSecretReferenceTests.swift. `swift test`: 1037 tests in 115 suites passed, 0 failures, 1 known issue (accepted withKnownIssue in HarnessSmokeTests), 0 compiler warnings (only the accepted SwiftPM "missing creator for mutated node" on mlx-swift_Cmlx.bundle). Both findings flipped to [x].
    - next: /review
  timestamp: 2026-10-20T16:52:08.845165+00:00
- actor: claude-code
  id: 01m5d3pxnxnrw2jr39wr4hwcdp
  text: |-
    ### test — green
    - evidence: touched MCPComposition.swift and MCPSecretReferenceTests.swift, then `swift test` — 1037 tests in 115 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue), no Swift compiler warning; `swift build --build-tests --package-path IntegrationTests` — Build complete, no Swift compiler warning. Only the known SwiftPM warning "missing creator for mutated node" on the mlx-swift_Cmlx bundle appeared.
    - next: review
  timestamp: 2026-10-20T16:53:28.893844+00:00
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

## Review Findings (2026-10-20 11:46)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Tools/MCPComposition.swift:455` `reuse/reuse` — The `normalize` function builds the `env` map and the `headers` map with two copies of the same loop: each takes a list of `{name, value}` pairs and stores `ConfiguredSecret(value)` under `name`. A second copy of the logic means a later change to the pair-to-map rule (for example, the last-name-wins rule) has to be made in two places. Add one private helper, for example `static func secretMap(_ pairs: [some NameValue]) -> [String: ConfiguredSecret]`, or a small generic over the two wire pair types, and call it from both cases of `normalize`. This keeps the last-repeated-name rule in one place.
- [x] `Tests/FoundationModelsACPAgentTests/MCPSecretReferenceTests.swift:361` `completeness/invariant-propagation` — `noLogRecordHoldsAValue` forbids `envValue` in the log, but the store passed to the load holds only the header reference. The env reference therefore never resolves, `envValue` is never read, and the forbidding check for it is vacuous. The env-value path has no log coverage, while the header path is covered. Load with `Self.storeWithItems` (or add `envReference: envValue` to the store) so both the header and env resolution paths run under the telemetry capture. Keep the assertions on the warning record's key path.
