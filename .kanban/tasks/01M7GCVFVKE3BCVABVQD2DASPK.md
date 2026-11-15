---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: Mount the sessions tool and fill restoreSession (ACPA-9)
---
From TestudoApp (testudoapp-75), Step 2 (session management and settings, D184; ACPA-9). Plan: TestudoApp `features/packages/foundationmodels-acpagent.md` ACPA-9.

- Mount `SessionsTool` of FoundationModelsMultitool as a top-level tool (a `sessions` GraphQL endpoint: Pinned and Recent lists, Switch to Session).
- Fill `restoreSession` of `SessionLauncher`.
- Mark a session as used when a client opens or resumes it.

BLOCKED until these exist: FoundationModelsMultitool MT-2/MT-10 (pin/unpin, pinnedSessions/recentSessions), FoundationModelsExtras EXTRAS-3 (`SessionSummary.pinned`/`lastUsedAt`, `setPinned`/`markUsed`). #blocked