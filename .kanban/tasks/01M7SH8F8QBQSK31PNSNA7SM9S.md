---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7skz5gp49fm2qze892e78jw
  text: |-
    Router D206 part 1 (^3566rvs) is on origin/main at 19a50552 (2026-11-19): `SessionSummary` gives `lastSummary`, `recap` and `recapAt` from the record, also after a restart. Also: each directory operation now finds a closed recorded fork (send, inbox, pin, archive and others threw `unknownSession` for it before). The recap maker and its on/off policy come in Router ^4maqy3m; the Router sends the policy API with its sha.
    Plan: change items 1, 2 and 5 (the configuration key, the settings tool and endpoint, the README) start now in a worktree branch. Item 3 (the policy to the Router) and the final bump wait for ^4maqy3m.
  timestamp: 2026-11-19T09:59:53.110239+00:00
- actor: claude-code
  id: 01m7smp0ggdtzj3jv3ys63307y
  text: 'Part 1 done (2026-11-19) in branch worktree-agent-afc8d230055b11a08 at 41533a1, not merged, not pushed. Change items 1, 2 and 5 are done: `sessions: { recap: true }` in builtin.config.yaml, `AgentConfiguration.sessions` (`SessionsConfiguration`, `recap`, default true), the settings tool and endpoint at the USER and SESSION levels, and README "The session recap". The description sentence is in the `settings` tool description (the schema has no per-key description). The folder function for the Router policy: `extension SettingsStore { public func isSessionRecapOn(for workingDirectory: URL) throws -> Bool }` (an actor method; it reads the merged value at each call, so a change applies at the next turn end; an outside file edit applies after the file watcher reloads). Tests: SessionRecapSettingTests; 2467 unit tests passed. Open: item 3 (connect the function to the Router recap policy) and item 4 (bump Router, Multitool, Extras) wait for Router ^4maqy3m. Continue on that branch.'
  timestamp: 2026-11-19T10:12:21.648375+00:00
- actor: claude-code
  id: 01m7stvmwcazag69j6yd2evghx
  text: 'Part 2 research (2026-11-19, main tree). Bump done: `swift package update` pins Router 0148db1 (0148db1258224a8c0608424013b45b26d7130977), Multitool 0775c99, Extras f99b111. Package.resolved is in .gitignore, so the bump changes no tracked file. Router API: `RouterSessionDirectory.useRecapPolicy(_:)` holds a synchronous `@Sendable (URL) -> Bool` in a Mutex; `recapSession(of:)` asks it at each turn end and before the call. `recapTarget(of:)` is internal: a test reaches it with `@testable import FoundationModelsRouter` (other tests already do this). The idle time is 20 s and `useRunClock` is internal, so the wiring test reads `recapTarget(of:)` of a live session and does not wait for a recap. Each host path (ComposedAgent, the acp-agent CLI, the test harness) makes a `RoutedACPAgent`, so the call goes in `RoutedACPAgent.init` beside `use(launcher:)`. Plan: `SettingsStore` keeps a Mutex snapshot of the rendered tree of each level that it holds (updated where `levels` changes: first read, set/clear, reload, stopWatching); `isSessionRecapOnNow(for:)` is nonisolated and merges the defaults layer, the user level and the folder level; a level that the store does not hold yet is read from the disk.'
  timestamp: 2026-11-19T12:00:17.804824+00:00
- actor: claude-code
  id: 01m7sv83ajbj0xd65b3nhg04aa
  text: 'Part 2 implementation done in the main tree, not committed. (1) Bump: Router 0148db1, Multitool 0775c99, Extras f99b111. The Router at 0148db1 did not compile against mlx-swift-lm 8e3daa7 (`cannot find type ''PromptCacheCopyResult''` in SessionPromptCache.swift), so mlx-swift-lm (stable) also went to c1b3d5e. Package.resolved is gitignored. (2) `SettingsStore` keeps `levelRoots`, a Mutex copy of the tree of each level that it holds; `keep(_:)` changes it with `levels` (first read, set/clear, reload); `stopWatching()` clears it. `mergedRootNow(for:)` (nonisolated) merges the defaults layer, the user level and the folder level; a level that the store does not hold is read from its file. `isSessionRecapOnNow(for:)` (public, nonisolated) decodes `sessions.recap`; on an error it logs a warning and gives true. `SessionsConfiguration.recap(in:)` is the shared decode of both reads. (3) `RoutedACPAgent.init` calls `useRecapPolicy` with that read; ComposedAgent, the CLI and the test harness all make a RoutedACPAgent, so no other call is necessary. (4) README "The session recap" and ARCHITECTURE "Settings" (the recap policy bullet) are updated. Tests: 5 new tests in SessionRecapSettingTests, and SessionRecapPolicyWiringTests (reads `recapTarget(of:)` through `@testable import FoundationModelsRouter`; the 20 s idle clock is internal, so no test waits for a recap). The 4 behavior tests failed first with a placeholder that gave true.'
  timestamp: 2026-11-19T12:07:05.810842+00:00
- actor: claude-code
  id: 01m7sv87y19g7rj857nx2fan9v
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Sources/FoundationModelsACPAgent/Configuration/SessionsConfiguration.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/SessionRecapSettingTests.swift, Tests/FoundationModelsACPAgentTests/SessionRecapPolicyWiringTests.swift (new), README.md, ARCHITECTURE.md; pins Router 0148db1, Multitool 0775c99, Extras f99b111, mlx-swift-lm c1b3d5e
    - next: /review

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings (all project sources recompiled); `timeout 1800 swift test --skip-build`: 2474 tests in 258 suites passed, 1 known issue (the existing withKnownIssue in HarnessSmokeTests), 0 failures
    - next: /review
  timestamp: 2026-11-19T12:07:10.529353+00:00
- actor: claude-code
  id: 01m7svceva837m61xgjp5m2v0j
  text: |-
    ### review — clean
    - evidence: review sha 41533a1~1..41533a1. 0 findings (0 confirmed, 0 refuted). 7 files attempted, 0 failed, 0 skipped. No validator matched README.md and Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml, so the engine did not review these 2 files.
    - next: review sha HEAD~1..HEAD (a68880c). The task goes to done only if that review is also clean.
  timestamp: 2026-11-19T12:09:28.682524+00:00
- actor: claude-code
  id: 01m7svj6fxxq7qknenq0dp481x
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a68880c). 4 findings (4 confirmed, 3 refuted). 7 files attempted, 0 failed, 0 skipped. Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:790 (reuse/reuse), Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:800 (reuse/reuse), Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:847 (completeness/invariant-propagation), Tests/FoundationModelsACPAgentTests/SessionRecapSettingTests.swift:102 (completeness/inverse-operation-coverage). The review of 41533a1~1..41533a1 before this one was clean.
    - next: Do the 4 items in the "Review Findings (2026-11-19 06:09)" section. Then review the fix commit again. The task stays in review.
  timestamp: 2026-11-19T12:12:36.733977+00:00
- actor: claude-code
  id: 01m7svnyf4ec4qwmavfe6yefkf
  text: 'Findings pass (2026-11-19) research. Finding 3 is the KEEP case. When the reload of a held level fails, `SettingsStore.reloaded(_:)` sets `loadError`, and the level keeps its last good `root` and `text`. `value(at:cwd:)` (thus `isSessionRecapOn(for:)`) merges `levelState(of:).tree` and does not throw. Thus the async read gives the last good value. The `levelRoots` copy stays the same. The contract goes into the doc comments of `isSessionRecapOn(for:)` and `isSessionRecapOnNow(for:)`. Plan for findings 1 and 2: `mergedSettings(over:)` becomes nonisolated. A new nonisolated `mergedSettings(for:treeOf:)` maps the watched levels and merges them, and both the async path and `mergedRootNow` call it. A nested `LevelFile` value (layer, file, `read()`) is the one lookup and read helper of `levelState(of:)`, `levelTreeNow(of:)` and `defaultsTrees()`.'
  timestamp: 2026-11-19T12:14:39.588181+00:00
- actor: claude-code
  id: 01m7svxbrf22fskpb1yc4k3mmq
  text: |-
    Findings pass done in the main tree, not committed. (1) `mergedSettings(over:)` is now nonisolated. The new nonisolated `mergedSettings(for:treeOf:)` is the one merge: the async `mergedSettings(for:)` gives it `{ try levelState(of: $0).tree }`, and `mergedRootNow(for:)` gives it `levelTreeNow(of:)`. (2) The new nested `LevelFile` (layer, `file`, `read()`) and `levelFile(of:)` (it replaces `layer(of level:)`) are the one lookup and read rule of `levelState(of:)`, `levelTreeNow(of:)` and `defaultsTrees()`. (3) KEEP case: the store keeps the last good tree of a held level after a failed reload, so the sync read does the same. The contract is in the doc comments of `isSessionRecapOn(for:)`, `isSessionRecapOnNow(for:)` and `mergedRootNow(for:)`. Test `bothReadsKeepTheLastGoodValueOfALevelThatBecomesUnreadable`: one load error, and both reads give false. (4) Tests `aUserLevelTurnsTheRecapOffForAFolderWithNoLevel` (both reads false) and `aFolderLevelTurnsTheRecapOnOverAUserLevelThatTurnsItOff` (both reads true). The 3 new tests passed at the first run, because they cover behavior that was already there. No production behavior changed.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift, Sources/FoundationModelsACPAgent/Configuration/SessionsConfiguration.swift, Tests/FoundationModelsACPAgentTests/SessionRecapSettingTests.swift
    - next: /review

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings (the only warning line is the build-system "missing creator for mutated node" note for the mlx bundle, which was there before the edit); `timeout 1800 swift test --skip-build`: 2477 tests in 258 suites passed, 1 known issue (the existing withKnownIssue in HarnessSmokeTests), 0 failures
    - next: /review
  timestamp: 2026-11-19T12:18:42.575816+00:00
position_column: doing
position_ordinal: '8180'
title: 'D206: the sessions.recap setting (user and folder level), given to the Router as its recap policy'
---
Decision D206 (j) in `TestudoApp/features/decisions.md` (commit da60a90). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/recap/acpa-brief.md`. Overview: `overview.md` in the same folder. The recap runs on the `flash` slot of the profile (D206 Q3 (b)).

## Dependencies (not on this board; wave 3)

- FoundationModelsRouter on `main` with D206 (`router-brief.md`): the recap maker and the recap policy of the directory.
- FoundationModelsMultitool on `main` with D206 (`mt-brief.md`).
- FoundationModelsExtras on `main` with D206 (`SessionSummary.recap`, `recapAt`).
Do not start until the Router sends the sha of its D206 work. Then bump the three packages.

## Current state

1. The builtin configuration has `theme`, `keymap`, `fonts`, `statusline` and `tools`, and no `sessions` section (`Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml:24-58`). Its tests make sure that the file decodes to the defaults in the code (`AgentConfiguration`).
2. The `settings` tool and the `settings` endpoint write the user level and the folder level, and `DotfolderStack` merges them (D100 (f)).
3. In each bundled profile, `flash` is the same model as `standard` (`Resources/profiles/large.yaml`, `medium.yaml`, `small.yaml`). The profiles do not change.

## Change

1. Add `sessions: { recap: true }` to `builtin.config.yaml`, with a comment in Simplified Technical English, and the matching field in `AgentConfiguration` (default true).
2. The `settings` tool and the `settings` endpoint read and write the key at both levels, with the description "Write a one-sentence recap of each session with the flash model (D206)."
3. Give the Router directory a recap policy that reads the merged value for the folder of each session, so a folder can turn it off. A change of the setting takes effect at the next turn end, with no restart (read the value when the policy is asked, not one time at start).
4. Bump FoundationModelsRouter, FoundationModelsMultitool and FoundationModelsExtras to the revisions with D206.
5. README: describe the setting.

## Tests

- The builtin file decodes to `recap == true`.
- A folder level with `sessions: { recap: false }` turns it off for a session in that folder and not for a session in a different folder.
- The `settings` tool sets the key, and the policy reads the new value with no restart.
- The `settings` endpoint reads and writes the key at the user and folder levels.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d206 #recap

## Review Findings (2026-11-19 06:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 8 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:790` `reuse/reuse` — mergedRootNow(for:) repeats the merge body of the existing store function at line 678 (`SettingsLevel.watched(cwd:).map { ... }` then `mergedSettings(over:)`). It differs only in the per-level tree source: levelTreeNow(of:) instead of levelState(of:).tree. Two copies of the same merge sequence can drift apart. A future change to the level order or to the defaults layer would have to be made twice. Extract one helper that takes the level-tree provider as a closure, for example `mergedTrees(over levelTree: (SettingsLevel) throws -> MergedSettings.LevelTree, cwd:)`. Pass `{ try levelState(of: $0).tree }` from the existing path and `levelTreeNow(of:)` from mergedRootNow. Keep the nonisolated path for the synchronous read.
- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:800` `reuse/reuse` — levelTreeNow(of:) repeats the lookup and read steps of levelState(of:): it resolves the layer, computes the config file, reads the text, and renders the tree. levelState(of:) at lines 717-732 does the same steps, and only the cache and the watcher differ. The file-to-tree rule now exists in two functions. Extract a nonisolated helper such as `readTree(of level:) throws -> (layer, file, text, root)` that both functions call. levelState keeps its cache and watcher. levelTreeNow keeps its lookup in levelRoots and skips the watcher.
- [x] `Sources/FoundationModelsACPAgent/Configuration/SettingsStore.swift:847` `completeness/invariant-propagation` — A held level that becomes unreadable after an outside write keeps its last good tree in `levelRoots`, so the synchronous read returns the old recap value. It does not fall back to the default. The default-on-failure rule in `isSessionRecapOnNow` (SessionsConfiguration.swift:94-95) is therefore applied only to a level the store has never loaded, not to a level it holds. Decide the contract for a held level that becomes unreadable. If the doc is right, make `levelTreeNow` or `mergedRootNow` treat a held level with a `loadError` as a failed read, so it logs and gives the default. Otherwise correct the doc at SessionsConfiguration.swift:94-95 and the `isSessionRecapOnNow` doc. Then add one test: a store-held folder level that turns the recap off, followed by an outside write of invalid YAML, asserting the value the contract names.
- [x] `Tests/FoundationModelsACPAgentTests/SessionRecapSettingTests.swift:102` `completeness/inverse-operation-coverage` — The synchronous recap read is tested only with a folder level that turns the recap off. No test sets `recap: false` at the user level and checks that `isSessionRecapOnNow(for:)` returns false for a folder with no level of its own. The user level is a separate layer in `mergedRootNow` and `levelTreeNow`, so its path is untested. Add one test. Write `recapOffYAML` to the user-level config of the fixture, then assert `fixture.store.isSessionRecapOnNow(for: fixture.firstDirectory) == false`. A folder-level `recap: true` override may be added to show the session level wins.