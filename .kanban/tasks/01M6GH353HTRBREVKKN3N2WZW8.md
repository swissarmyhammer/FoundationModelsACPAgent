---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gjcrcrjtfnb7zft14v002w
  text: 'DESIGN RULE (user, 2026-11-03): every session is the same kind of thing; a root session is a session with no parent. Do not write "if child" branches or a parallel path. Keep one code path for all sessions. What differs is data: `parentSessionId` (nil for the root) and the capabilities of the session entry, which come from the parent link (the root has all, a child has only what its `capabilities` advertise, today `cancel`). See the first task of this plan (shared session build and the session tree).'
  timestamp: 2026-11-03T11:23:29.560382+00:00
depends_on:
- 01M6GH2K0VV6RWV5R6SN3HB9SV
position_column: todo
position_ordinal: '8280'
title: 'Per-session capabilities: a child allows only what it advertises; refuse every other client mutation of a child'
---
## What
A child session is an ordinary session whose capabilities differ by DATA. Do not write "if child" branches (design rule, user 2026-11-03). Give each session entry a capability set: `entry.capabilities.permits(method)`. The root has all of them. A child has only what it advertises in `subagent_update.capabilities` (today only `cancel`). Every client mutation not advertised is refused, also a method added later (the default is "not permitted").

Methods to gate (in `Sources/FoundationModelsACPAgent/Agent/`): `session/prompt` (`PromptExecution.swift`), close, delete, fork (`SessionLifecycle.swift`), load and resume (`SessionResume.swift`), set mode and set config option (`ConfigOptions.swift`). Refuse with a typed `RequestError` that names the child and the method. `session/cancel` on a child is permitted when the child advertises `cancel` (the cancel task does the work). Do not offer the slash commands of a child as input.

`session/list`: children are found through the parent, not as standalone entries. Check what `session/list` returns today for a recorded sub-agent session (the listing goes through the Router transcript store; I did not verify whether it already leaves out sessions with an `agentSpawn`). Write the finding in a task comment. If sub-agents are listed, leave them out; if not, add only a regression test.

Needs the wire type for the child capabilities (FoundationModelsACP wire card `01M6GJ664BHY454C5NFPFCSP79`).

## Acceptance Criteria
- [ ] The session entry has a capability set; the root permits all methods; a child permits only `cancel`.
- [ ] `session/prompt`, close, delete, fork, load, resume, set mode and set config option on a child id each return the typed error.
- [ ] A method that the gate does not know is refused for a child.
- [ ] No `if child` branch outside the capability set.
- [ ] `session/list` never returns a child id (regression test).

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionCapabilityTests.swift`: one test for each refused method, the unknown method, the root, and the list.
- [ ] Run `swift test --filter SessionCapabilityTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.