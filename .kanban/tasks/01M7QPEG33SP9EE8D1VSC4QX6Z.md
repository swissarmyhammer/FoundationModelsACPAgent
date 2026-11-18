---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rg7wezyfc80v2k2dm4b0nx
  text: |-
    ### review — findings
    - evidence: review sha 3f24079~1..3f24079; findings 3, confirmed 3, refuted 4, attempted 21, failed 0. Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:112 (completeness/public-output-contract), ModelsEngine.swift:112 (swift/preconditions), ModelsEngine.swift:121 (swift/preconditions). No validator matched README.md, and the engine did not review it.
    - next: correct the 3 findings in the section "Review Findings (2026-11-18 17:31)". The task stays in review.
  timestamp: 2026-11-18T23:35:30.015500+00:00
- actor: claude-code
  id: 01m7rhc4h7mens264tdfb9xemh
  text: |-
    Review fix (2026-11-18). `ModelsEngine.selectedProfile` has no silent fallback now:
    - A `profile` value that does not decode: an error log record (key path `profile`, error type and case), and the decode error goes to the caller, as the load does.
    - A selected profile file that does not read: an error log record with `profile.name` (new key `LogMetadataKey.profileName`), and the error goes to the caller, as the load does (`aBadSelectedProfileFileIsAnError` of the loader).
    - An unknown name: the fallback stays (D203), with a warning log record.
    - `fallbackProfile` is a throwing function: a log record and the error go to the caller. An `unknownProfile` there is a programmer error (the fallback name is bundled), thus `assertionFailure` too. A user file that does not decode does not stop the agent.
    - `slots(holding:)` had a `try?`: now a warning log record, and the change names each slot, so that a subscriber reads again and gets the error.
    - No assertion for a bad user file, because a bad user config must not crash.
    Tests: `ModelsGraphTests.anUndecodableProfileValueIsAnError`, `aBadSelectedProfileFileIsAnError`, `aBadFallbackProfileFileIsAnError` (RED before, GREEN after). Note: the `sah tool kanban task get` CLI did not complete in 120 s in this tree; use the MCP tool.
    This change also removes the cause of the ^t2t3zww finding on `fallbackProfile`.
  timestamp: 2026-11-18T23:55:17.927540+00:00
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: doing
position_ordinal: '8180'
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

## Review Findings (2026-11-18 17:31)

> Scope: `review sha 3f24079~1..3f24079` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:112` `completeness/public-output-contract` — The new `try? setting.value.decoded()` turns a value of `profile` that does not decode into a silent nil, and the function then returns the default profile. A malformed value is no longer reported to the caller. The load path reports this as a decode error, so the two paths now disagree. Use `try setting.value.decoded()` so a decode failure propagates as the rest of the function does, or document in the doc comment that an undecodable value falls back to the default profile, and add a test that pins that behaviour.
- [x] `Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:112` `swift/preconditions` — The `try?` on the decode of the stored profile setting turns a decode failure into nil. The guard then takes the default-profile exit with no assertion and no log record. A stored value that does not decode is an unexpected condition, and this silence hides it from the author and from the operator. Use `try` in place of `try?` so that the decode error propagates, or, if the default must stay, call `assertionFailure` and write a `logger.error` record that names the setting key before the default is returned.
- [x] `Sources/FoundationModelsACPAgent/Models/ModelsEngine.swift:121` `swift/preconditions` — The catch-all `catch { return BundledProfiles.defaultProfile }` silently absorbs any error that the profile read throws, other than unknownProfile. A profile file that does not decode is an unexpected condition, but no assertion and no log record show it. The defect is hidden from the author in debug builds and from the operator in release builds. The `try?` on the fallback read at line 119 has the same silent shape. In the catch-all, call `assertionFailure("profile read failed: \(error)")` and `logger.error(...)` with the error type and the profile name, and then return the default profile. Do the same for the fallback read at line 119, and do not discard its error with `try?`.