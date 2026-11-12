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
position_column: todo
position_ordinal: '9280'
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
- [ ] After `session/close`, the skills registry of that session has no running watcher.
- [ ] A new `SKILL.md` after the close gives no reload of the closed registry (a control session that stays open shows the change).

## Tests
- [ ] A close test in `Tests/FoundationModelsACPAgentTests/` like the close tests of `AgentCatalogWatchTests.swift`.
- [ ] `swift test` passes with no warnings. #step1