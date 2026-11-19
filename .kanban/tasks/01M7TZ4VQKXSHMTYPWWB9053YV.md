---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tz8ptjcw5e116v6phx4ybq
  text: 'Research done. D206 (j) says `sessions.recap` is at the user level AND the folder level. D207 (i) Q73 says `sessions.spotlight` is "at the user level" only, and "off removes all items of the app" (deleteAllSearchableItems): the effect is app wide, so a folder value has no meaning. Decision: user level only. The SettingsEngine (shared by the settings tool and the settings endpoint) refuses an updateSetting at the SESSION level whose value reaches `sessions.spotlight` (key path ["sessions","spotlight"] or ["sessions"] with a `spotlight` key) with a new code USER_LEVEL_ONLY and a corrective message. A clearSetting at the SESSION level stays allowed: it can only remove a hand-written value. No per-key level rule existed before; the new rule is a list of user-level-only key paths in SettingsEngine.'
  timestamp: 2026-11-19T22:36:34.514521+00:00
- actor: claude-code
  id: 01m7tzrw4wma03gmdz402x807h
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml (spotlight: true), Configuration/SessionsConfiguration.swift (spotlight field, default true, decode, spotlightDescription, spotlightKeyPath), Configuration/AgentConfiguration.swift (doc), Configuration/ConfigurationYAML.swift (section comment), Settings/SettingsGraphError.swift (new case userLevelOnly, code USER_LEVEL_ONLY), Settings/SettingsEngine.swift (userLevelOnlyKeyPaths and the refusal in set), Settings/SettingsTool.swift (description sentence), README.md (section "The Spotlight setting"), Tests/.../SessionSpotlightSettingTests.swift (new, 10 tests), Tests/.../SettingsGraphTests.swift (userLevelOnly in errorOfEachCase).
    - level rule: user level only (D207 (i) Q73 names only the user level; D206 names both for recap). updateSetting at SESSION that reaches sessions.spotlight gives USER_LEVEL_ONLY and writes nothing; clearSetting at SESSION is allowed. sessions.recap at SESSION still works.
    - RED seen: compile failure on the missing members, then 4 level-rule tests failed on behavior before the engine rule.
    - next: /review

    ### test — green
    - evidence: `timeout 1800 swift build --build-tests` printed "Build complete!" with 0 compiler warnings (only the SwiftPM note "missing creator for mutated node" of the mlx bundle, from before this change). `timeout 1800 swift test --skip-build`: 2660 tests in 281 suites passed, 0 failures; 1 known issue is the intended withKnownIssue in HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps.
    - next: /review
  timestamp: 2026-11-19T22:45:24.252121+00:00
position_column: doing
position_ordinal: '8180'
title: 'D207 (i): the sessions.spotlight setting (Boolean, on by default) in the configuration and the settings tool/endpoint'
---
Gap from the TestudoApp session (2026-11-19). Decision D207 (i) and Q73.

## Current behavior

The settings store knows only the `recap` key in the `sessions` section (^na7sm9s). Thus it refuses `sessions.spotlight` with INVALID_VALUE: `unknown key "spotlight" in section "sessions"`. The app writes `sessions.spotlight` from its General pane toggle. The app's integration test records this as a known issue, which will fail when the key exists.

## Change

1. Add `spotlight: true` to the `sessions` section of `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`, with a comment in Simplified Technical English (the app writes Core Spotlight items of the sessions when it is on; the agent does not act on it).
2. Add the matching field to `SessionsConfiguration` / `AgentConfiguration.sessions` (default true). It decodes and merges like `recap`.
3. The `settings` tool and the `settings` endpoint read and write `sessions.spotlight`. The user level is the level that the app writes; follow the same levels as `recap` unless D207 says user level only (then refuse the folder level with a clear corrective, and say which you chose).
4. Add the sentence for the key to the settings tool description, as for `recap`.
5. README: describe the key.
6. The agent does not act on the setting.

## Tests

- The builtin file decodes to `spotlight == true`.
- The settings tool and the endpoint set and read `sessions.spotlight` at the user level.
- `sessions.recap` still works.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d207 #search