---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7347fhdvrp55qzj6pd4ggxt
  text: |-
    Research (implement step).

    The card says that a `session/resume` of a live nested session goes to the cold path and to `tearDownSession`. The code does not do that. `restoreSession` in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift` calls `requirePermitted(ACPMethod.sessionResume, on: params.sessionId)` before `liveRoot`. A nested session in the table has `SessionCapabilitySet(advertised: SubagentAnnouncer.childCapabilities)` (`SessionBuild.swift`). That set permits only `session/cancel`. Thus the request gets `methodNotPermitted` and stops before the hot path and before the teardown.

    The refusal is a documented contract:
    - `SessionCapabilitySet` doc: "A child session permits only what it advertises in `subagent_update.capabilities`. The default is not permitted."
    - The wire type `SubagentSessionCapabilities` (FoundationModelsACP, generated from the ACP schema, `Generated/Models10.generated.swift`) has only `cancel`. It has no resume capability.
    - The test `SessionCapabilityTests.resumeOnAChildIsRefused` asserts the typed refusal of `session/resume` on a live child (`refusedForChild` lists `ACPMethod.sessionResume`).

    Second finding: `ConnectionTable.take(_:by:)` checks only `state.owners[sessionId]`, not the lineage. A nested session has no owner record of its own, so an `external` connection could take a nested session whose root another connection owns. The hot nested resume must check the effective owner (`owner(of:)`, along the lineage) to obey D120 c.
  timestamp: 2026-11-10T16:21:30.797387+00:00
- actor: claude-code
  id: 01m7347mhwrx820b53bq1jd1hg
  text: |-
    ### implement — stuck
    - blocker: a true conflict. The card requires that `session/resume` of a live nested session attaches it. The capability contract of a child session refuses `session/resume`: a child permits only what `subagent_update.capabilities` advertises, and `SubagentSessionCapabilities` has no resume field. The test `SessionCapabilityTests.resumeOnAChildIsRefused` asserts this refusal. The implement step did not resolve the conflict itself.
    - decision needed (a person must choose one):
      (a) Add a resume capability to `SubagentSessionCapabilities` in FoundationModelsACP (a sibling repository; the type is generated from the ACP schema, so the schema or an extension must change), then advertise it in `SubagentAnnouncer.childCapabilities` and map it in `SessionCapabilitySet.init(advertised:)`.
      (b) Make `session/resume` an agent-side exception that `SessionCapabilitySet` permits for a child with no advertised capability. This changes the documented rule of `SessionCapabilitySet` and the test `resumeOnAChildIsRefused`, and the card must say so.
    - also needed in the card: the owner check of a nested take. `ConnectionTable.take` reads only the owner record of the session, not its lineage.
    - evidence: no files changed; no tests run (no code change).
    - next: a person updates the card with the decision, then implement runs again.
  timestamp: 2026-11-10T16:21:35.932395+00:00
- actor: claude-code
  id: 01m7348cfdy5v14ma1ecw26ejc
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — no code change. The card premise is wrong. A resume of a live nested session is refused with `methodNotPermitted` (`requirePermitted` in SessionResume.swift). It does not go to the teardown. `SubagentSessionCapabilities` has only `cancel`, and `SessionCapabilityTests.resumeOnAChildIsRefused` tests this contract.
    - Decision asked of testudoapp-75 (2026-11-10): (r) recommended, no code change, close with a test of the hot resume of a root that `sessions start` made; (a) a resume capability in FoundationModelsACP; (b) an exception for resume in this package. For (a) or (b), `ConnectionTable.take(_:by:)` must check the owner along the parent chain (D120 c).
    - next: wait for the decision.
  timestamp: 2026-11-10T16:22:00.429712+00:00
- actor: claude-code
  id: 01m7348n6076x06xqt83dgv8xc
  text: |-
    Decision of testudoapp-75 (2026-11-10): choice (r). Make no production code change. A nested session opens only through its root. The hot resume of a root (d8fa169) takes over the whole tree.
    New scope of this task:
    - [ ] Find a test that shows this: a root session that `sessions start` makes (not a nested `agents` run), while its prompt runs, gets `session/resume` from a second connection. Then it has no teardown, its prompt goes on to its end, and the new connection gets the replay. If no test covers it, add it to the hot resume test file.
    - [ ] Do not change `resumeOnAChildIsRefused` or `SessionCapabilitySet`.
    - [ ] When done, send the test commit and d8fa169 to testudoapp-75 with the text for the ACPA-11 status. testudoapp-75 edits the TestudoApp docs.
  timestamp: 2026-11-10T16:22:09.344693+00:00
position_column: doing
position_ordinal: '8180'
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