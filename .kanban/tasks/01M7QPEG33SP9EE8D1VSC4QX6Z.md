---
assignees:
- claude-code
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: todo
position_ordinal: '8980'
title: 'ACPA-23 (D203): an unknown profile name gives a warning and the fallback, not a load failure'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, part 3.

## Dependency

^56r9vp9 (the three bundled profiles).

## Current state

- `ProfileStore.read` throws `unknownProfile` (`Configuration/ProfileStore.swift:160-165`; the text at `:75-76`). `ConfigurationLoader.resolvingProfile` passes the error on (`Configuration/ConfigurationLoader.swift:459-465`). `SessionSetup.load` fails (`Agent/SessionSetup.swift:557-561`), so `session/new` fails.
- A write through the settings store is checked with the loader (`SettingsStore.check`, `Configuration/SettingsStore.swift:604-612`), so a write of an unknown name is refused.
- `ConfigurationWarning` exists (`Configuration/ConfigurationLoader.swift:52`), and the loader logs each warning.

## Change

1. A `profile` name that no layer has gives a new `ConfigurationWarning`. The warning names the value and the available names. The load does not throw, so `session/new` starts.
2. The load then uses the fallback profile. Until the fit task lands, the fallback is `small`. The fit task changes it to the largest profile that fits, with `small` when no fit can be read. Make the fallback one function, so that the fit task changes one place.
3. A write of an unknown name through the `settings` endpoint or tool is still refused. Keep the check of `SettingsStore.check` for a write, also when the loader does not throw at load.
4. The `acp-agent` CLI gets the same behavior.
5. README: describe the warning.

## Tests

- `profile: nosuch` at the user level loads with one `ConfigurationWarning` that names `nosuch` and the available names, and uses the fallback profile.
- `session/new` starts with `profile: nosuch`.
- A write of `nosuch` through the settings store is refused.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d203 #profiles #acpa-23