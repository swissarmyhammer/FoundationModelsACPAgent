---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'ACPA-11: Attach a live nested session on session/resume with no teardown'
---
## What
Spec: ACPA-11 (TestudoApp/features/packages/foundationmodels-acpagent.md). Decisions D11, D68.

The hot resume of a live root session is done (`d8fa169`, card 01M6GK6AH3R589GF241923KNDP, `Sources/FoundationModelsACPAgent/Agent/SessionResumeHot.swift`). The gap: `liveRoot(_:)` returns `nil` when `parentSessionId != nil`. Thus `session/resume` of a live nested session goes to the cold path in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` (~183-200): `takeSession`, then `tearDownSession`, then a restore from disk. That stops the work of the live session.

1. `SessionResumeHot.swift`: replace `liveRoot(_:)` with `liveSession(_:)`, which returns the entry of any live session that is not closed, root or nested.
2. `resumeLiveSession`: for a nested session, take the session and the sessions nested in it (`treeSessionIds(of:)`), withdraw their open questions from the old connection, replay their history, and sync the current state. The parent and the root keep their owner. Use the owner rules of `takeSession` (D120 c, `external` connections).
3. The teardown and the restore stay only for a session that is not live.

## Acceptance Criteria
- [ ] A `session/resume` of a live nested session does not call `tearDownSession`, and its running prompt goes on to its end.
- [ ] The new connection gets the replay of the nested session history and its later updates.
- [ ] The owner of the root does not change.
- [ ] A resume of a session that is not live still restores from disk.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionResumeHotTests.swift` (or the current hot resume test file): a test that starts a sub-agent run with a gated stub model, resumes the nested session from a second connection, and confirms the four criteria.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1