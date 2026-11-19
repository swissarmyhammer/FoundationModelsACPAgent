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