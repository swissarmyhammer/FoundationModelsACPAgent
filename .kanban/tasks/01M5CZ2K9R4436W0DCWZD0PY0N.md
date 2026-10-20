---
assignees:
- claude-code
depends_on:
- 01M5CZ1HFBGK6JN6N4MY5ZY1HZ
position_column: todo
position_ordinal: '8680'
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
- Give `ConfiguredSecret` an optional `reference: String?` (the name after `keychain:`). Decoding: a string that starts with `keychain:` is a reference; the value comes from the `SecretStore` of the previous card, which the loader puts in the decoder `userInfo`. Another string is a literal value with no reference.
- If the store returns nil or throws: add a `ConfigurationWarning` (`ConfigurationLoader.swift:81-85`) that names the key path and the reference, never a value, and leave the key out of the decoded map (the key acts as not set).
- Encoding: a reference encodes as `keychain:<name>` in all `SecretForm` cases (`ConfigurationYAML.swift:47-57`). A literal keeps the current behavior (`<redacted>` or omitted).
- `description`, `debugDescription` and the mirror show `keychain:<name>` for a reference and stay redacted for a literal.
- `doctor` (`ConfigurationDoctor`): one line for each reference with no item, with the reference name.
- The telemetry rule (`ACPAgentTelemetry.swift:1-15`) stays true: extend `TelemetryContentSafetyTests` with a reference and its value.

## Acceptance Criteria
- [ ] `tavily: keychain:tavily-api-key` with an item gives `TAVILY_API_KEY` = the value in the web tool environment (`environment(mergedOver:)`, line 456).
- [ ] With no item: one warning names `tools.web.apiKeys.tavily` and `tavily-api-key`, and the key is not set.
- [ ] A literal key still loads.
- [ ] `config show` (YAML and `--json`), `/config`, `/config export` and `doctor` show `keychain:tavily-api-key` and never the value.

## Tests
- [ ] Load tests with `InMemorySecretStore`: a reference with an item, a reference with no item, a literal.
- [ ] A round-trip test: decode then encode with each `SecretForm` gives `keychain:tavily-api-key`.
- [ ] A test that the value is not in the `config show` output, the `doctor` output or a captured log.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18