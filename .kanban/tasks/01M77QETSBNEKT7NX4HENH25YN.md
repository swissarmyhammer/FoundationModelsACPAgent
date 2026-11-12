---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77qqz53mewdypc8snxxg7sr
  text: 'Decision of testudoapp-75 (2026-11-12): step1. Order: after ^vshf002, before 01M73SQXB1HB5HFV6YVC4HAFQW. Request sent to foundationmodelsskills-f7 for a public, idempotent `SkillsRegistry.stopWatching() async`, the same shape as `AgentRegistry.stopWatching()` (Agents b210589). When it is pushed: bump only the Skills pin (and any family package that it needs), call it from `SessionSurface.shutdown()` next to the agent registry stop, and add a close test like the agent close tests in AgentCatalogWatchTests.swift (a control session that stays open, no clock).'
  timestamp: 2026-11-12T11:19:31.747753+00:00
- actor: claude-code
  id: 01m77qsehzkrkkn30gbnab2aet
  text: The Skills card is ^tx4z2pz (01M77QRNRJ6QQMGD9DQTX4Z2PZ, FoundationModelsSkills board, step1). foundationmodelsskills-f7 started it on 2026-11-12 and will send the commit.
  timestamp: 2026-11-12T11:20:20.287775+00:00
- actor: claude-code
  id: 01m77qy47c30chfhsw25vnnbyd
  text: 'Skills ^tx4z2pz is on main: e07d9b0 (code), 08f54fa (card). `public func stopWatching() async` on SkillsRegistry: it stops the watcher and the marketplace task, and waits for a rebuild in progress. A second call does nothing, watch: false does nothing, reload() still works with no new watcher. Skills tests: StopWatchingTests. This card is no longer blocked. Next run: bump only the Skills pin to 08f54fa or later, call `stopWatching()` on the skills registry of the session in `SessionSurface.shutdown()` next to the agent registry stop, and add a close test like the agent close tests in AgentCatalogWatchTests.swift.'
  timestamp: 2026-11-12T11:22:53.548284+00:00
- actor: claude-code
  id: 01m77s5ept7718fej0sja4gtz0
  text: 'Research (implement): `SessionSurface.shutdown()` in Tools/ToolCatalog.swift stops the agent registry with `agents?.registry.stopWatching()`. The skills registry of the session is `agents.environment.skills` (FoundationModelsAgents `AgentEnvironment.skills`). It is a copy of the `SkillsSource.registry` that SessionSetup makes for each session, and the copies share one `ReloadCoordinator`. Thus a stop on it stops the watcher of the session registry. Each session makes its own skills registry, so a stop does not touch another session. Skills 55aa12c has an internal `SkillsRegistry.isFollowingChanges` (true while the watcher or the marketplace task runs); a test reads it with `@testable import FoundationModelsSkills`. Pins: `swift package update FoundationModelsSkills FoundationModelsAgents` moved Skills 1421de4 -> 55aa12c and Agents b5fbe7b -> a8a2153, in the root and in IntegrationTests. No other package moved. Package.resolved is in .gitignore, thus the pin change is local only and has no diff in git.'
  timestamp: 2026-11-12T11:44:22.234323+00:00
- actor: claude-code
  id: 01m77sevr7dmpr0acqdmwcbr3x
  text: |-
    Implementation landed (TDD). Two close tests were added to AgentCatalogWatchTests.swift: `aClosedSessionLeavesNoRunningSkillsWatcher` and `aNewSkillAfterTheCloseGivesNoChangeToTheClosedSession`. They use the `WatchFixture` of that suite again. The helper opens a second session, reads its skills registry (`surface.agents?.environment.skills`), closes the session, then writes `<cwd>/.skills/late-skill/SKILL.md` and `later-skill`. After each write, it waits on the `onReload` of the registry of the control session until that registry has the skill (no clock). RED before the change: both tests failed (`!closedRegistry.isFollowingChanges`, and the closed registry listed `late-skill`). GREEN after the change: `SessionSurface.shutdown()` calls `await agents?.environment.skills.stopWatching()` after the agent registry stop. The docs of `shutdown()` and of `AgentsMount.environment` tell about the stop. The tests read the internal `SkillsRegistry.isFollowingChanges` through `@testable import FoundationModelsSkills`.

    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift, Tests/FoundationModelsACPAgentTests/AgentCatalogWatchTests.swift. `swift build --build-tests`: complete, 0 compiler warnings (all own sources touched first). `swift test`: 2006 tests in 220 suites passed, 0 failures, 1 known issue (the planned `withKnownIssue` in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: complete, 0 compiler warnings. SwiftPM gives one build-system line, `missing creator for mutated node` for the mlx-swift_Cmlx bundle; it is not a compiler warning and does not come from this change. Pins (root and IntegrationTests): FoundationModelsSkills 1421de4 -> 55aa12c (08f54fa is an ancestor), FoundationModelsAgents b5fbe7b -> a8a2153. No other package moved. Package.resolved is in .gitignore, thus the pin change is local and has no git diff. No commit.
    - next: review
  timestamp: 2026-11-12T11:49:30.503783+00:00
position_column: doing
position_ordinal: '8180'
title: The skills registry of a closed session stops its watcher
---
## What
Found on ^a84x0wm (2026-11-12). The skills registry of a session (`ToolCatalog.makeSkillsSource`, `SkillsRegistry(... watch: true ...)`) keeps a running `DotfolderWatcher` after `session/close`.

Cause: `session/close` keeps the closed session entry and its `SessionSurface`. The surface keeps `AgentsMount.environment`, and the environment keeps the `SkillsRegistry`. Only `ReloadCoordinator.deinit` of FoundationModelsSkills stops the watcher. `SkillsRegistry` (FoundationModelsSkills 1421de4, the current origin/main) has no public stop.

Evidence: a probe test (not kept) opened a control session and a second session in one working directory, closed the second session, and wrote `<cwd>/.skills/probe-one/SKILL.md` and then `probe-two`. After the control registry gave both reloads, `metadata()` of the closed registry listed `["probe-one", "probe-two"]`. So its watcher still ran.

## Plan
1. FoundationModelsSkills (sibling repository, a new pin): add a public `SkillsRegistry.stopWatching() async`, the same contract as `AgentRegistry.stopWatching()` (idempotent; stops the watcher and the follow of the marketplace updates; `metadata()` keeps the last catalog).
2. This repository: move the Skills pin, and call the stop from `SessionSurface.shutdown()` for the skills registry of the session.

## Acceptance Criteria
- [x] After `session/close`, the skills registry of that session has no running watcher.
- [x] A new `SKILL.md` after the close gives no reload of the closed registry (a control session that stays open shows the change).

## Tests
- [x] A close test in `Tests/FoundationModelsACPAgentTests/` like the close tests of `AgentCatalogWatchTests.swift`.
- [x] `swift test` passes with no warnings. #step1