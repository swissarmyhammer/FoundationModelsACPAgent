---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8fbt2a7nnszz1wvqce6cjks
  text: 'Research: I touched every Swift file in Sources/ and Tests/ and ran `swift build --build-tests`. That gave 12 UnnecessaryEffectMarker warnings. One is a site the card does not list: Sources/FoundationModelsACPAgent/Models/ModelsGraphChanges.swift:120 (`await store.changes()`, where store is the SettingsStore from the engine). The other 11 are the listed SettingsEngine (2) and test sites. I left `await profiles.changes()` in the same file as it is: ProfileStore.changes() is actor-isolated, not nonisolated, and the compiler does not warn there. Fix: dropped only the needless `await` on the 12 warned lines. No behavior changes, so no new test; the proof is a build with zero compiler warnings.'
  timestamp: 2026-11-27T20:40:34.887073+00:00
- actor: claude-code
  id: 01m8fbxxwn6cddd2vdasa57a4b
  text: |-
    ### implement — changed
    - evidence: 6 files changed (12 lines). Sources/FoundationModelsACPAgent/Settings/SettingsEngine.swift, Sources/FoundationModelsACPAgent/Models/ModelsGraphChanges.swift, Tests/FoundationModelsACPAgentTests/{SettingsStoreTests,SettingsStoreSecretFlushTests,SessionSettingsStoreTests,SessionRecapSettingTests}.swift. I touched every Swift file and ran `swift build --build-tests`: 12 "no 'async' operations" warnings before, 0 after, and 0 compiler warnings in total. The only line left is the SwiftPM "missing creator for mutated node" notice about the mlx bundle, which is not a compiler warning. `swift test`: exit 0, 2935 tests in 316 suites passed. The 1 known issue is the expected withKnownIssue in HarnessSmokeTests.
    - next: /review
  timestamp: 2026-11-27T20:42:41.429833+00:00
- actor: claude-code
  id: 01m8fbzg217xkga1hs4sy367db
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (68767474) — 0 findings, 0 confirmed, 0 refuted; 7 validator passes attempted, 0 failed, 0 skipped; 6 files reviewed, 2 .kanban files excluded by .reviewignore
    - next: none; task moved to done
  timestamp: 2026-11-27T20:43:32.801392+00:00
- actor: claude-code
  id: 01m8fbzsfres33yjt5m3594gmx
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files
    - test: green — swift test 2935 passed (1 known issue), 0 'no async' warnings
    - commit: 68767474
    - review: clean
  timestamp: 2026-11-27T20:43:42.456278+00:00
position_column: done
position_ordinal: ffffffc480
title: no 'async' operations warnings on await of SettingsStore.changes()
---
`swift build --build-tests` warns "no 'async' operations occur within 'await' expression" at each `await store.changes()` / `await agent.settingsStore.changes()`: Sources/FoundationModelsACPAgent/Settings/SettingsEngine.swift (two sites), Tests SessionSettingsStoreTests, SettingsStoreSecretFlushTests, SettingsStoreTests (several), SessionRecapSettingTests. `SettingsStore.changes()` became `nonisolated` in bbe77e50 (2026-11-24), so the `await` is needless. Drop each needless `await` so the build has zero warnings. Found while working ^j1vfmkf; not caused by it.