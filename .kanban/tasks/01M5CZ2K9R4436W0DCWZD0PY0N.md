---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d0zqn20ph87fpm72dfwama
  text: |-
    Research. The card says: "the value comes from the SecretStore ... which the loader puts in the decoder userInfo". The loader cannot do this without a change in FoundationModelsExtras.

    Facts:
    - `ConfigurationLoader.configuration(from:)` decodes with `YAMLValue.decoded(as:)` (FoundationModelsExtras, YAMLValue.swift, revision f164745 on main).
    - `decoded(as:)` calls `YAMLDecoder().decode(T.self, from: yamsNode())` and has no `userInfo` parameter. `yamsNode()` is fileprivate.
    - `YAMLValue` is not `Codable`, so a JSON round trip with `JSONDecoder.userInfo` is not available without a second tree conversion that changes the decode errors (`YAMLValueDecodingError`).
    - This package does not depend on Yams. The Extras manifest says that Yams stays inside Extras.

    Thus the card needs a change in FoundationModelsExtras, for example a public `decoded(as:userInfo:)` overload that gives `userInfo` to `YAMLDecoder.decode(_:from:userInfo:)`.

    Other possible decision (needs approval, because it changes a decision of the card): decode `keychain:<name>` as a reference with no value, and let the loader resolve each reference through the store after the decode, with no decoder userInfo.

    No code changed.
  timestamp: 2026-10-20T16:05:51.906751+00:00
- actor: claude-code
  id: 01m5d0zt54yfy2atz4y1mgrejf
  text: |-
    ### implement — stuck
    - evidence: no files changed. Blocker: `YAMLValue.decoded(as:)` in FoundationModelsExtras has no `userInfo` parameter, so the loader cannot put the `SecretStore` in the decoder `userInfo` as the card orders.
    - next: a person decides. Either open a task on FoundationModelsExtras for `decoded(as:userInfo:)`, or change this card to resolve references in the loader after the decode.
  timestamp: 2026-10-20T16:05:54.468112+00:00
- actor: claude-code
  id: 01m5d17yw33cws53gqd85f3zrt
  text: |-
    Picked up again after the card change (resolve pass in the loader, no decoder userInfo). Research:
    - Loaders are made in `RoutedACPAgent.makeConfigurationLoader` (SessionSetup.swift), `ComposedAgent.compose` (start-up load), `AgentComposition.makeConfigurationLoader` (CLI `config show`, `doctor`, `instructions`). Each gets the store: the agent passes `secretStore`, the CLI default is the login Keychain under the dotfolder name.
    - `ConfiguredSecret` gets private enum storage (literal, or reference with an optional resolved value) so no impossible state exists. `value` becomes `String?`; `WebToolOptions.environment(mergedOver:)` skips a nil value, so an unresolved reference never becomes an empty key.
    - New `ConfigurationWarning.unresolvedSecret(keyPath:reference:)`. The doctor lists it through the existing warning path, with its own fix text.
    - `/config export` (SecretForm.omitted) now keeps references and drops literals. The confirmation note of the export changes to say so.
    - Unit tests stay hermetic: `makeStubAgent` gets a `secretStore` parameter with an `InMemorySecretStore` default, and the loader test fixture, the `config show` helper and the doctor helper pass an `InMemorySecretStore`.
  timestamp: 2026-10-20T16:10:21.443919+00:00
- actor: claude-code
  id: 01m5d1rnf4gyska6v5x86dfnph
  text: |-
    Implementation landed (TDD: SecretReferenceTests failed at compile first, then the CLI tests in ConfigShowTests and ConfigurationDoctorTests failed at compile before the CLI seams existed).
    - `ConfiguredSecret` holds a private enum `Source` (literal, or reference with an optional value). `value` is now `String?`: `nil` only for a reference with no value. `WebToolOptions.environment(mergedOver:)` skips a `nil` value, so an unresolved reference never becomes an empty key (test `anUnresolvedReferencePutsNothingIntoTheEnvironment`).
    - `ConfigurationLoader` takes `secretStore:` (default: `KeychainSecretStore.loginKeychain(for:)`, shared with `RoutedACPAgent`). `load()` decodes, then resolves the web API key references, then logs one `unresolvedSecret(keyPath:reference:)` warning for each reference with no item or a store error.
    - `RoutedACPAgent.makeConfigurationLoader`, `ComposedAgent.compose` (start-up load), `AgentComposition.makeConfigurationLoader` and `config show` report pass the store. `doctor` gets a fix text that names the reference.
    - `/config export` (SecretForm.omitted) keeps references and drops literals. The confirmation note says so.
    - Test support: `makeStubAgent`, `ScriptedPromptFixture.make` and the BuiltinCommandsTests fixture take `secretStore:` with an `InMemorySecretStore` default, so no unit test touches the real Keychain.
    - README and the comment in builtin.config.yaml now describe `keychain:<name>`.
    - The build warning "missing creator for mutated node" (mlx-swift Cmlx bundle) is pre-existing; earlier cards record that it reproduces on main.
  timestamp: 2026-10-20T16:19:28.868887+00:00
- actor: claude-code
  id: 01m5d1rtd8by9gjax58ezhjgx3
  text: |-
    ### implement — changed
    - evidence: `swift test` — 1019 tests in 114 suites passed, 0 failed (1 known issue is the deliberate `withKnownIssue` in HarnessSmokeTests; the one build warning is the pre-existing mlx-swift Cmlx bundle message). `swift build --package-path IntegrationTests --build-tests` builds. Files: Sources/FoundationModelsACPAgent/Configuration/{ConfiguredSecret,ConfigurationLoader,ConfigurationYAML,KeychainSecretStore,ToolSectionCodec}.swift, Sources/FoundationModelsACPAgent/{RoutedACPAgent,ComposedAgent}.swift, Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift, Sources/FoundationModelsACPAgent/Commands/BuiltinCommands.swift, Sources/FoundationModelsACPAgent/Doctor/ConfigurationDoctor.swift, Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml, Sources/acp-agent/{AgentComposition,ConfigCommand}.swift, README.md, Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift, Tests/FoundationModelsACPAgentTests/{SecretReferenceTests (new),ConfigurationLoaderTests,ConfigShowTests,BuiltinCommandsTests,TelemetryContentSafetyTests}.swift, Tests/FoundationModelsACPAgentTests/Doctor/ConfigurationDoctorTests.swift, Tests/FoundationModelsACPAgentTests/Support/ScriptedPromptFixture.swift
    - next: /review
  timestamp: 2026-10-20T16:19:33.928093+00:00
- actor: claude-code
  id: 01m5d1vfjbmxp47mvaes8jz0se
  text: |-
    ### test — green
    - evidence: touched the changed Swift files, then `swift test`: 1019 tests in 114 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted). `swift build --build-tests --package-path IntegrationTests`: Build complete. Compiler warnings: none. Only the accepted SwiftPM "missing creator for mutated node" warning on mlx-swift_Cmlx.bundle.
    - next: review
  timestamp: 2026-10-20T16:21:01.131830+00:00
depends_on:
- 01M5CZ1HFBGK6JN6N4MY5ZY1HZ
position_column: doing
position_ordinal: '80'
title: 'ACPA-18: keychain: references in config.yaml load as ConfiguredSecret'
---
## What
ACPA-18 and D101: a secret in `config.yaml` is `keychain:<name>`, for example:

```yaml
tools:
  web:
    apiKeys:
      tavily: keychain:tavily-api-key
```

ACPAgent looks up the reference when it loads a layer, and gives the value as a `ConfiguredSecret`. A reference with no item gives a diagnostic that names only the reference, and the key acts as not set. A literal secret still loads. `config show`, `doctor` and the logs show only the reference.

Now `ConfiguredSecret` (`Configuration/ConfiguredSecret.swift:19-78`) holds only `value`. It decodes a plain string and always encodes `"<redacted>"`. Its only user is `WebToolOptions.apiKeys` (`ToolSectionCodec.swift:381-470`).

Do this:
- Give `ConfiguredSecret` an optional `reference: String?` (the name after `keychain:`). Decoding: a string that starts with `keychain:` is a reference with no value yet. Another string is a literal value with no reference. After the decode, `ConfigurationLoader` resolves each reference through the `SecretStore` of the previous card (a resolve pass over the decoded `AgentConfiguration`). Do not use the decoder `userInfo`: `YAMLValue.decoded(as:)` of FoundationModelsExtras has no `userInfo` parameter, and this card does not change Extras. (Card changed on 2026-10-20 after the first implement step.)
- If the store returns nil or throws: add a `ConfigurationWarning` (`ConfigurationLoader.swift:81-85`) that names the key path and the reference, never a value, and leave the key out of the decoded map (the key acts as not set).
- Encoding: a reference encodes as `keychain:<name>` in all `SecretForm` cases (`ConfigurationYAML.swift:47-57`). A literal keeps the current behavior (`<redacted>` or omitted).
- `description`, `debugDescription` and the mirror show `keychain:<name>` for a reference and stay redacted for a literal.
- `doctor` (`ConfigurationDoctor`): one line for each reference with no item, with the reference name.
- The telemetry rule (`ACPAgentTelemetry.swift:1-15`) stays true: extend `TelemetryContentSafetyTests` with a reference and its value.

## Acceptance Criteria
- [x] `tavily: keychain:tavily-api-key` with an item gives `TAVILY_API_KEY` = the value in the web tool environment (`environment(mergedOver:)`, line 456).
- [x] With no item: one warning names `tools.web.apiKeys.tavily` and `tavily-api-key`, and the key is not set.
- [x] A literal key still loads.
- [x] `config show` (YAML and `--json`), `/config`, `/config export` and `doctor` show `keychain:tavily-api-key` and never the value.

## Tests
- [x] Load tests with `InMemorySecretStore`: a reference with an item, a reference with no item, a literal.
- [x] A round-trip test: decode then encode with each `SecretForm` gives `keychain:tavily-api-key`.
- [x] A test that the value is not in the `config show` output, the `doctor` output or a captured log.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18