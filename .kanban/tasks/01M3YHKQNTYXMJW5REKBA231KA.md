---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yjav1tqqs5ma0bfr2n3hzr
  text: |-
    Research done.
    - Multitool c56729b builds and the test targets compile with no change (`swift build --build-tests` green). No fix for the update was necessary.
    - Multitool API: `WebConfiguration.fromEnvironment(_:)`, `.keyless`, `WebSearchProvider.name`, `WebAPIKey.resolve(in:)`, `MultiTool.Builder.withWeb(configuration:sessionConfiguration:)`. `WebCapability` does not expose its configuration, thus the provider order is tested through one shared function that makes the `WebConfiguration` (ToolCatalog and doctor and `config show` call it).
    - `ConfigurationYAML.documentText` has four callers: `/config`, `/config export`, `config show`, `config init`. `config show --json` encodes `AgentConfiguration` with `JSONEncoder` directly. Thus the redaction goes in the `Encodable` form of the key value, so each encoding path shows `<redacted>`.
    - `/config export` writes the effective configuration into a layer. A `<redacted>` value in a layer would replace the real key in a lower layer (dictionaries merge by key in `LayeredYAMLDocument`). Decision: the export writes `apiKeys: {}` (no key values). An empty map in a higher layer keeps the keys of the lower layers, thus the effective configuration does not change, and no key goes into a file that can be committed.
    - plan.md §11.2 says that a tool body has no `enabled:` key. The card orders `tools.web.enabled`. Decision: the web section takes both shapes: `web: false` (the shared codec rule) and `web: {enabled: false}`. plan.md records the exception.
    - The built-in instructions do not list the tool groups ("the tools change with the session"), thus no change there.
    - Process environment: `CatalogContext` and `ToolsDoctor` get an `environment` parameter whose default is `ProcessInfo.processInfo.environment`, so a test gives its own dictionary.
  timestamp: 2026-10-02T15:04:43.322189+00:00
- actor: claude-code
  id: 01m3yk7j0wx5g8kh2vkmhjp9z8
  text: |-
    Implementation landed.
    - Codec: `ToolsConfiguration.web: ToolSection<WebToolOptions>` with `enabled` (default true) and `apiKeys: [WebAPIKeyName: ConfiguredSecret]`. `web: false` and `web: {enabled: false}` both turn it off (`ToolSection<WebToolOptions>.mountedOptions`). An unknown `apiKeys` name gives the new `ConfigurationError.unknownMapKey(section:key:validKeys:)`, whose text lists `brave, tavily, exa, serper, kagi, searxngURL`.
    - `ConfiguredSecret` (new file Configuration/ConfiguredSecret.swift): description, debugDescription, mirror and the `Encodable` form give `<redacted>`. Thus `/config`, `config show` (YAML, `--source`, `--json`) and any log of the configuration show no key.
    - `ConfigurationYAML.documentText(for:annotation:secrets:)`: `.redacted` (default, for a person) or `.omitted` (for a layer file: `apiKeys: {}`), through the encoder user-info flag `CodingUserInfoKey.omitsConfiguredSecrets`. `/config export` and `config init` use `.omitted`; the export confirmation says that the file holds no `tools.web.apiKeys` value. Reason: a `<redacted>` value in a layer would replace the real key of a lower layer, and the real value must not go into a project file that can be committed. Limit: an export into the same layer that holds the keys removes them from that layer; the confirmation says so.
    - `WebComposition` (new file Tools/WebComposition.swift): `configuration(options:processEnvironment:)` = `WebConfiguration.fromEnvironment(options.environment(mergedOver:))`; `providerNames(section:processEnvironment:)`; `compose(into:context:)` calls `builder.withWeb(configuration:)`. `ToolCatalog.makeRegistry` mounts it after the shell.
    - `CatalogContext.environment` and `ToolsDoctor(environment:)` default to the process environment; `DoctorCommand` passes its environment. Doctor row "the web tool": "on; the search providers in order: ..." or the disabled row that names `tools.web.enabled`.
    - `config show` YAML ends with `# tools.web search providers in force, in order: ...` (provider names from `WebConfiguration.providers.map(\.name)`, the same names that `WebConfiguration.description` shows, without its fetch policy text). The `--json` form stays the bare tree, because JSON holds no comment.
    - Docs: README Tools row and a `tools.web` section; plan.md §11.2 exception note, §11.3 roster row, §11.4 `web` bullet (not in the sandbox, `WebAddressGuard`); bench/code-context.config.yaml `web: enabled: false` with the reason; bench/README.md note.
    - Existing test changed: `ToolsDoctorTests.disabledShellRowCount` 2 -> 3 (the web row is new).
  timestamp: 2026-10-02T15:20:24.348932+00:00
- actor: claude-code
  id: 01m3yk7r95vjnr5y7nzm5jg26t
  text: |-
    ### implement — changed
    - evidence: 20 files. New: Sources/FoundationModelsACPAgent/Configuration/ConfiguredSecret.swift, Sources/FoundationModelsACPAgent/Tools/WebComposition.swift, Tests/FoundationModelsACPAgentTests/WebToolTests.swift. Changed: ToolSectionCodec.swift, ConfigurationLoader.swift, ConfigurationYAML.swift, CatalogContext.swift, ToolCatalog.swift, ToolsDoctor.swift, BuiltinCommands.swift, acp-agent/ConfigCommand.swift, acp-agent/DoctorCommand.swift, ToolCatalogTests.swift, ToolsDoctorTests.swift, ConfigShowTests.swift, BuiltinCommandsTests.swift, README.md, plan.md, bench/README.md, bench/code-context.config.yaml. `swift build -c release`: complete, 0 warnings. `swift test`: 707 tests in 79 suites passed (1 known issue, the deliberate negative in HarnessSmokeTests). No test sends a request. Package.resolved not changed; the Multitool c56729b update needed no fix.
    - next: /review
  timestamp: 2026-10-02T15:20:30.757886+00:00
- actor: claude-code
  id: 01m3ym6zdw6x86apj7c9aae6h3
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPAgentTests/WebToolTests.swift:178 (code-hygiene/disallowed-constructs-swift, no_direct_standard_out_logs)
    - next: remove the print/debugPrint/dump call from WebToolTests.swift (and each other such call in that file), then review again
  timestamp: 2026-10-02T15:37:33.884172+00:00
- actor: claude-code
  id: 01m3ymwv3tk8nwysevcqmtvb36
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (f2a3d2a). 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 1 file reviewed. All prior findings are checked.
    - next: none. The task is in done.
  timestamp: 2026-10-02T15:49:30.362763+00:00
- actor: claude-code
  id: 01m3ymx2a84bkmczk7aw5xmxd3
  text: |-
    ### finish iteration 2 — clean
    - iteration 1: implement changed (20 files), test green (707 tests / 79 suites), commit 9a331b5, review findings (WebToolTests.swift:178)
    - iteration 2: implement changed (WebToolTests.swift: mirror in place of dump), test green (WebToolTests 14/14), commit f2a3d2a, review clean
  timestamp: 2026-10-02T15:49:37.736714+00:00
position_column: done
position_ordinal: ff8f80
title: 'Mount the Multitool web capability by default: keyless search with no setup, and an API key in config or the environment selects a keyed provider'
---
## Why

Multitool (pinned `ef905bf`) has a web capability: `tools.web.search` and `tools.web.fetch`, mounted with `MultiTool.Builder.withWeb(configuration:)`. The agent does not mount it now. The owner wants it on by default, so that it searches with no API key, and an API key changes the provider.

Multitool already has the provider logic (`.build/checkouts/FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Web/WebConfiguration.swift`):
- `WebConfiguration.keyless`: `braveHTML`, then `duckDuckGoHTML`. No key.
- `WebConfiguration.fromEnvironment(env)`: each keyed provider whose variable is set, in this order: `braveAPI` (`BRAVE_SEARCH_API_KEY`, else `BRAVE_API_KEY`), `tavily` (`TAVILY_API_KEY`), `exa` (`EXA_API_KEY`), `serper` (`SERPER_API_KEY`), `kagi` (`KAGI_API_KEY`), `searxng` (`SEARXNG_URL`). The keyless providers always come last, as the fallback. An empty variable is not set. Keys are `.environment(name)` and are read at each call. No string form shows a key.

## Decisions

1. **On by default.** `ToolCatalog` mounts the web capability for each session unless `tools.web.enabled: false`.
2. **No key: it searches.** With no key and no setting, the providers are `[braveHTML, duckDuckGoHTML]`.
3. **Environment keys work with no config.** The agent passes its process environment to `WebConfiguration.fromEnvironment`. Thus `export TAVILY_API_KEY=...` before the agent starts selects Tavily first.
4. **Config keys.** A new `tools.web.apiKeys` map in `config.yaml`, with keys `brave`, `tavily`, `exa`, `serper`, `kagi`, and `searxngURL`. A value is merged into the environment dictionary under the provider's variable (`brave` -> `BRAVE_SEARCH_API_KEY`, `searxngURL` -> `SEARXNG_URL`, the others -> `<NAME>_API_KEY`) before `fromEnvironment`. A config value wins over the process environment for the same variable. Config layers merge as the other sections do. Use Multitool's table order; do not add a provider-order setting.
5. **No key ever shows.** `config show`, `/config`, `doctor`, logs and spans show a key as `<redacted>` (or `set`), never the value. `config show` lists the provider order in force by name (use `WebConfiguration.description`, which shows names only).
6. **Doctor.** `doctor` gets one check line for the web capability: enabled or not, and the provider order by name. It makes no network call.
7. **SWE-bench stays honest.** `bench/code-context.config.yaml` sets `tools.web.enabled: false`, with a comment: a web search can find the upstream fix of the issue, and the score must measure the agent alone. Note this in `bench/README.md` beside the other config keys, if that file still lists keys.
8. **The sandbox.** The web verbs run in the agent process through URLSession, not under the seatbelt shell sandbox. Multitool's `WebAddressGuard` blocks private and local addresses. State this in `plan.md` where the tools are listed.

## What to do

- `ToolSectionCodec` (or the codec of the tool sections): decode `tools.web.enabled` (Bool, default true) and `tools.web.apiKeys` (map). An unknown key in `apiKeys` is an error that names the valid keys.
- `ToolCatalog`: when enabled, call `builder.withWeb(configuration: WebConfiguration.fromEnvironment(merged))`, where `merged` is the process environment plus the config keys (decision 4).
- `config show`, `/config`, `doctor`: decisions 5 and 6.
- The instructions or tool catalog text that lists the tool groups: add `tools.web` if such a list exists.
- `plan.md` and the root `README.md` configuration section: document the section, the variables, the order, and the default.

## Tests

- No config, empty environment: the session surface has `tools.web.search` and `tools.web.fetch`, and the provider order is `[braveHTML, duckDuckGoHTML]`.
- Environment `TAVILY_API_KEY=x`: the order is `[tavily, braveHTML, duckDuckGoHTML]`.
- Config `tools.web.apiKeys.exa: y`: the order starts with `exa`; with both env `EXA_API_KEY=a` and config `exa: b`, the key in force is `b` (test through `WebAPIKey.resolve(in:)` of the configuration's environment, or the merged dictionary).
- `tools.web.enabled: false`: no `tools.web` verbs.
- An unknown `apiKeys` key: a config error that names the valid keys.
- `config show` with a key set: the output does not contain the key value.
- No test makes a network call.
- `swift build -c release` with no warnings, and `swift test` passes. #tools

## Review Findings (2026-10-02 10:21)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 16 file(s) reviewed, 8 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `bench/README.md` — no validator matches this file
> - `bench/code-context.config.yaml` — no validator matches this file
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/WebToolTests.swift:178` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
