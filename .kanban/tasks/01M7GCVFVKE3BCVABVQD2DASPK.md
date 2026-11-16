---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7gfgg2yahg1c95r9fwteq7b
  text: |-
    ### Research before the work (2026-11-15)
    - ACPAgent has no `SessionLauncher` conformance now. Router `RouterSessionDirectory.use(launcher:)` exists; with no launcher, `start(_:)` throws `noLauncher`.
    - Multitool `SessionsTool(directory:)` exists on main. It is a `GraphQLEndpointTool` (one `SessionsGraph` for each directory).
    - Plan for Step 2: (1) make `ComposedSessionLauncher: SessionLauncher` over `RoutedACPAgent`; fill `restoreSession(id:)` through the `session/resume` composition (`composeSession(... resuming:)`); `launchRootSession` stays for Step 7 (give a clear error). (2) Call `router.sessionDirectory.use(launcher:)` in the agent init. (3) Add one `SessionsTool(directory:)` for each session as a top-level tool in `ToolCatalog.makeStandaloneTools`, next to `skills` and `agents`, always on. (4) Call the Extras `markUsed` when `session/new`, `session/load` or `session/resume` opens a session.
    - Waits for: Multitool `pinnedSessions`/`recentSessions` (MT-2/MT-10), Extras `setPinned`/`markUsed`/`lastUsedAt` (EXTRAS-3). A background watch checks origin/main of both repositories every 2 minutes.
  timestamp: 2026-11-15T20:48:48.222929+00:00
- actor: claude-code
  id: 01m7gfjgjxwax4affcj8bwq7f5
  text: |-
    ### Storage of pinned and recent (2026-11-15)
    The user said: "be thoughtful where you store pinned and recent sessions".
    - Do not store them in the per-session facts beside each recording. The default root `<cwd>/.<name>/transcripts/` can be in git or iCloud Drive (a pin goes to another Mac, against D118(e)). After a restart Router knows only some roots (Recent misses closed projects). markUsed would write in the user's repository at each open.
    - Store them in one machine-local usage store for each server: `AgentHome.local` (App Group container in TestudoApp), for example `<local>/sessions/usage.json`. Keep the pinned ids, and the lastUsedAt and recording root of each id. A cap on recent entries never drops a pin.
    - Proposed: Extras `SessionUsageStore` (protocol + JSON file), Router `RouterSessionDirectory.use(usageStore:)`, ACPAgent makes the store and gives it. Sent to foundationmodelsextras-0a and testudoapp-75.
  timestamp: 2026-11-15T20:49:54.269268+00:00
position_column: done
position_ordinal: fffff080
title: Mount the sessions tool and fill restoreSession (ACPA-9)
---
From TestudoApp (testudoapp-75), Step 2 (session management and settings, D184; ACPA-9). Plan: TestudoApp `features/packages/foundationmodels-acpagent.md` ACPA-9.

- Mount `SessionsTool` of FoundationModelsMultitool as a top-level tool (a `sessions` GraphQL endpoint: Pinned and Recent lists, Switch to Session).
- Fill `restoreSession` of `SessionLauncher`.
- Mark a session as used when a client opens or resumes it.

BLOCKED until these exist: FoundationModelsMultitool MT-2/MT-10 (pin/unpin, pinnedSessions/recentSessions), FoundationModelsExtras EXTRAS-3 (`SessionSummary.pinned`/`lastUsedAt`, `setPinned`/`markUsed`). #blocked