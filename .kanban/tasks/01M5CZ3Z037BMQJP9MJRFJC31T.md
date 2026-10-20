---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dmxq0pt0aahr3vef6pr9ta
  text: 'Research: `SettingsStore.change` edits the source tree of the level (`SettingsSourceText`) and writes that source text. It does not encode the decoded `AgentConfiguration`. Thus a `keychain:` reference and a literal stay as the file text, and no value from the secret store can go into a flush. `SettingsChange` holds only the level and the key path, thus no value goes into a change event. `reload` logs only the error metadata. The existing test `aFlushKeepsEachSecretReference` covers one Tavily reference only. Plan: no production change. Add a suite `SettingsStoreSecretFlushTests` that reuses `SettingsStoreTests.Fixture` (made internal) and covers all web API keys, the MCP headers and the MCP env (reference and literal), a check after each flush, no move of a literal to another level, and no literal in a change event.'
  timestamp: 2026-10-20T21:54:17.238586+00:00
- actor: claude-code
  id: 01m5dn2tdaen1gkyed04v37ps1
  text: |-
    Each acceptance criterion holds with the current code, so I made no production change. The new tests prove the criteria: `Tests/FoundationModelsACPAgentTests/SettingsStoreSecretFlushTests.swift` has 4 tests (web API keys with 3 references and 3 literals, the MCP headers and env with a reference and a literal each, no secret goes from the user level into the session file, and no secret goes into a change event). Each flush (two `set` and one `clear`) reads the file and checks it: the `tools` section is unchanged, each `keychain:<name>` is still there, and no `InMemorySecretStore` value is in it. `SettingsStoreTests.Fixture` changed from private to internal so the new suite can use it. Because the tests prove behavior that already exists, they passed on the first run. A flush that encodes the decoded configuration would make them fail: the literal header would become `<redacted>`, and a resolved value would show in the file.

    ### implement — no-change
    - evidence: no change to production code. Tests added in Tests/FoundationModelsACPAgentTests/SettingsStoreSecretFlushTests.swift (new, 4 tests). Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift changed so that `Fixture` is internal. `swift test`: 1166 tests in 126 suites passed, 0 failures. There is 1 known issue: the deliberate `withKnownIssue` in HarnessSmokeTests, which existed before this task. There is 1 SwiftPM build-system note, "missing creator for mutated node", on the mlx-swift_Cmlx bundle, which also existed before this task.
    - next: /review
  timestamp: 2026-10-20T21:57:04.554159+00:00
- actor: claude-code
  id: 01m5dn2z5cjw8kbkfzrh05d8jw
  text: |-
    ### implement — changed
    - correction: the step record above has the wrong outcome word. Test files changed, thus the outcome is `changed`. No production code changed.
    - evidence: 2 files. Tests/FoundationModelsACPAgentTests/SettingsStoreSecretFlushTests.swift is new, with 4 tests. Tests/FoundationModelsACPAgentTests/SettingsStoreTests.swift changed so that `Fixture` is internal. `swift test`: 1166 tests in 126 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-10-20T21:57:09.420889+00:00
- actor: claude-code
  id: 01m5dn7cygvcapxhekep458xrf
  text: |-
    ### test — green
    - evidence: touched the two changed test files, then `swift test` — 1166 tests in 126 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue), 0 compiler warnings; `swift build --build-tests --package-path IntegrationTests` — build complete; `swift test --filter 'SettingsStoreSecretFlushTests|SettingsStoreTests'` run 3 times — 22 tests in 3 suites passed each time. Only the accepted SwiftPM "missing creator for mutated node" warning on mlx-swift_Cmlx appeared.
    - next: review
  timestamp: 2026-10-20T21:59:34.608986+00:00
depends_on:
- 01M5CZ35E8P2EZTW5GW3YTW5VX
- 01M5CZ2K9R4436W0DCWZD0PY0N
position_column: doing
position_ordinal: '80'
title: 'ACPA-18: the settings flush writes only keychain: references'
---
## What
ACPA-18 and D101(c): the flush of the settings object writes only a reference, never a value. A literal secret that a user typed into `config.yaml` still loads.

Do this in the flush of `SettingsStore`:
- A `ConfiguredSecret` with a reference writes `keychain:<name>`.
- A `ConfiguredSecret` with a literal value that was in the file: the flush keeps the literal text that the user typed in that file, and does not add it to another file. It never moves a literal from one level to another. (The flush writes the document of the level that it read; it does not encode the decoded `AgentConfiguration`.)
- A literal never goes into a log, a change event or a subscription.

## Acceptance Criteria
- [x] After a `set` on another key, a reference in the same file stays `keychain:<name>`.
- [x] After a `set` on another key, a literal secret in the same file stays the same text.
- [x] No flush writes a value that came from the Keychain.

## Tests
- [x] A test with `InMemorySecretStore` that reads the file after each flush and finds no Keychain value in it.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18 #acpa-17