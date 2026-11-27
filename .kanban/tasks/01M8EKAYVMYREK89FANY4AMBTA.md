---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: no 'async' operations warnings on await of SettingsStore.changes()
---
`swift build --build-tests` warns "no 'async' operations occur within 'await' expression" at each `await store.changes()` / `await agent.settingsStore.changes()`: Sources/FoundationModelsACPAgent/Settings/SettingsEngine.swift (two sites), Tests SessionSettingsStoreTests, SettingsStoreSecretFlushTests, SettingsStoreTests (several), SessionRecapSettingTests. `SettingsStore.changes()` became `nonisolated` in bbe77e50 (2026-11-24), so the `await` is needless. Drop each needless `await` so the build has zero warnings. Found while working ^j1vfmkf; not caused by it.