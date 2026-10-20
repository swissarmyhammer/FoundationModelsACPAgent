---
assignees:
- claude-code
depends_on:
- 01M5CZ35E8P2EZTW5GW3YTW5VX
- 01M5CZ2K9R4436W0DCWZD0PY0N
position_column: todo
position_ordinal: 8b80
title: 'ACPA-18: the settings flush writes only keychain: references'
---
## What
ACPA-18 and D101(c): the flush of the settings object writes only a reference, never a value. A literal secret that a user typed into `config.yaml` still loads.

Do this in the flush of `SettingsStore`:
- A `ConfiguredSecret` with a reference writes `keychain:<name>`.
- A `ConfiguredSecret` with a literal value that was in the file: the flush keeps the literal text that the user typed in that file, and does not add it to another file. It never moves a literal from one level to another. (The flush writes the document of the level that it read; it does not encode the decoded `AgentConfiguration`.)
- A literal never goes into a log, a change event or a subscription.

## Acceptance Criteria
- [ ] After a `set` on another key, a reference in the same file stays `keychain:<name>`.
- [ ] After a `set` on another key, a literal secret in the same file stays the same text.
- [ ] No flush writes a value that came from the Keychain.

## Tests
- [ ] A test with `InMemorySecretStore` that reads the file after each flush and finds no Keychain value in it.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18 #acpa-17