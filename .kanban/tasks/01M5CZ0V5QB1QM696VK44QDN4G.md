---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d44kvy0m7zp1pqmbgf1a0g
  text: |-
    Research and implementation notes:
    - `SnapshotStore.open` (FoundationModelsHooks) makes the shadow folder `<store>/<sessionKey>` on `SessionStart` when the cwd is a git work tree. Thus one stub turn in a git work tree is enough to make the shadow folder. FoundationModelsHooks did not change.
    - The stub (echo) model cannot run a tool call through `ComposedAgent.compose`. The file that the turn writes is the transcript in `<cwd>/.<name>/transcripts/` (the default `TranscriptLocation.project`). The test checks that this folder is not empty.
    - `composeStubAgent` did not set `XDG_DATA_HOME` before. Thus each stub composition wrote its hook data into the real `~/.local/share/<name>/hooks`. The helper now sets `XDG_DATA_HOME` to a throwaway folder (or to the new `dataHome` parameter), and it takes the new `hooksDataDirectory` parameter.
    - `ComposedAgentTests`: the private `initialize` helper now calls a generic `exchange` helper, so the new `runOneTurn` helper uses the same wire set-up and teardown. `runOneTurn` waits for the idle update before it closes the wire. Without that wait, the log showed `A session/update send failed` warnings.
    - The DocC symbol links to `compose(...)` in `ComposedAgent.swift`, `GatedStubModel.swift` and `acp-agent/AgentComposition.swift` now include `hooksDataDirectory:`.
  timestamp: 2026-10-20T17:00:57.598479+00:00
- actor: claude-code
  id: 01m5d44pv60q7hnmtrrjahp7ta
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/ComposedAgent.swift, Sources/FoundationModelsACPAgent/Configuration/GatedStubModel.swift, Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTestSupport/StubComposition.swift, Tests/FoundationModelsACPAgentTests/ComposedAgentTests.swift, Tests/FoundationModelsACPAgentTests/HookCompositionTests.swift. RED: the build failed with "extra argument 'hooksDataDirectory' in call". GREEN: the 2 new tests pass. `swift test`: 1039 tests in 115 suites passed, 0 failures, 1 known issue (the `withKnownIssue` that was there before in HarnessSmokeTests), and no compiler warnings. `swift build --build-tests --package-path IntegrationTests` builds.
    - next: /review
  timestamp: 2026-10-20T17:01:00.646401+00:00
- actor: claude-code
  id: 01m5d47gr3b3m3dty74gfneq8z
  text: |-
    ### test — green
    - evidence: touched the 6 changed files, then `swift test`: 1039 tests in 115 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue, accepted). `swift build --build-tests --package-path IntegrationTests`: Build complete. No compiler warning. Only the accepted SwiftPM "missing creator for mutated node" warning on mlx-swift_Cmlx.bundle appears.
    - next: review
  timestamp: 2026-10-20T17:02:32.707088+00:00
- actor: claude-code
  id: 01m5d4ab69jwb0fr2kf14ka013
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 1c6522b). 0 findings, 0 confirmed, 0 refuted. 6 files reviewed. 4 .kanban files not reviewed because of the ignore rule.
    - next: none. The task is in done.
  timestamp: 2026-10-20T17:04:05.321588+00:00
- actor: wballard
  id: 01m5d4aktf1hq0q1pdfz4cj64r
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files
    - test: green — swift test 1039 passed; IntegrationTests builds
    - commit: 1c6522b
    - review: clean — 0 findings; task is done
  timestamp: 2026-10-20T17:04:14.159546+00:00
position_column: done
position_ordinal: ffef80
title: 'ACPA-15: the host gives the snapshot data directory'
---
## What
ACPA-15 (TestudoApp `features/packages/foundationmodels-acpagent.md`, D96): the store directory of the persistent snapshot timeline must stay in a folder that macOS does not clean. The CLI uses the XDG data home. The app uses Application Support. Never Caches or a temporary folder.

Now `AgentHooks.init(dataDirectory:)` (`Sources/FoundationModelsACPAgent/Agent/AgentHooks.swift:47-51`) makes the `SnapshotStore` in `<data>/snapshot`. Only `AgentHooks.dataDirectory(name:environment:)` (lines 65-69) gives `<data>`: `$XDG_DATA_HOME/<name>/hooks`, else `~/.local/share/<name>/hooks`. The host cannot give an other folder. `ComposedAgent.compose(...)` (`ComposedAgent.swift:135`, the call at line 148) always uses that helper.

Do this:
- Add an optional parameter `hooksDataDirectory: URL? = nil` to `ComposedAgent.compose(...)`. When it is not nil, use it for `AgentHooks(dataDirectory:)`. When it is nil, keep the XDG data home.
- Document on the parameter that the app gives a folder in Application Support (for example `<Application Support>/<bundle id>/hooks`), and never Caches or a temporary folder.
- The CLI (`Sources/acp-agent/AgentComposition.swift`) gives nothing, so it keeps the XDG data home.
- Do not change FoundationModelsHooks.

## Acceptance Criteria
- [x] `ComposedAgent.compose` takes `hooksDataDirectory`, and the `SnapshotStore` uses `<hooksDataDirectory>/snapshot`.
- [x] With no value, the folder is the same as before.
- [x] The CLI behavior does not change.

## Tests
- [x] A test composes an agent with a temporary `hooksDataDirectory`, runs one turn that writes a file, and finds the shadow folder of the session key under `<hooksDataDirectory>/snapshot`.
- [x] A test that with no value the folder is `AgentHooks.dataDirectory(name:environment:)` for a given `XDG_DATA_HOME`.
- [x] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-15