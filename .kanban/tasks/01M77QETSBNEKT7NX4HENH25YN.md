---
assignees:
- claude-code
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
- [ ] `swift test` passes with no warnings.