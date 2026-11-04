---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m6gmvgfepp84ky8paym1vy52
  text: |-
    PLAN REVIEW FIX (2026-11-03). The description above is correct except where this comment corrects it; where they conflict, this comment wins and the description is to be rewritten before the task starts.
    This task is stale: do not create SubagentSessionTable or SubagentProjector (design rule: one code path for all sessions). The client package now has a card. Rewrite to: the real acp-agent binary and the client over the wire; criteria: cold resume order (replay, background updates, state_update, session info, response, then child snapshots), hot resume, cancel of one child, session/list shows only the root. Depends on the resume cards.
  timestamp: 2026-11-03T12:06:30.126099+00:00
depends_on:
- 01M6GM17VHZSWD4G2J27WTA3JT
- 01M6GK6AH3R589GF241923KNDP
- 01M6GH3GPC9H1JYKV6GVANTFD9
- 01M6GH3NTR334G36C0FMY9MBDF
- 01M6GH3TN6QK7ZCSXTNWD6MNVW
- 01M6GH43RRA3D4ACVCWNWSAMY7
- 01M6GH3ZHE52GHWAZ53AWNKJ0K
position_column: doing
position_ordinal: '80'
title: 'Integration test: nested sub-agent run end to end over the ACP wire, and update the docs'
---
## What
Prove the whole path with the real `acp-agent` binary and the ACP client, not only with unit tests.

- Add `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SubagentSessionsTests.swift`. Follow the shape of the existing tests there (spawned `acp-agent`, the `FoundationModelsACPClient` side). Use the stub or echo model of `Sources/FoundationModelsACPAgent/Configuration/` so no real model is needed. The prompt makes the root start an agent, and that agent starts a nested agent.
- Update `ARCHITECTURE.md` and `README.md`: say that a sub-agent is an ACP child session, say where it is projected, and name the restrictions. `ARCHITECTURE.md` needs an update because a new component (`SubagentSessionTable`, `SubagentProjector`) joins the structure.
- Update the comments of `RunCallJoinTable` and `AgentsComposition` that say the agent run sends no wire update.

Note: the ACP client package (`FoundationModelsACPClient`) has no code for child sessions today (`ConnectionModel` and `SessionModel` route by session id from `session/list` and `session/new`). If the client drops or mishandles updates of an unknown child id, this test shows it. Do NOT change the client package from this task. Write the finding in the task comment; a card on that project must be discussed with the user first.

## Acceptance Criteria
- [ ] The test sees, in order: `subagent_update` (child), `subagent_update` (grandchild), child events under each id, `idle` for each.
- [ ] `session/list` shows only the root session.
- [ ] `session/cancel` on the child id ends only the child.
- [ ] `session/resume` with `replayFrom: start` replays the chain parent first.
- [ ] `ARCHITECTURE.md` and `README.md` describe the new components.

## Tests
- [ ] The new `SubagentSessionsTests` in the IntegrationTests package.
- [ ] Run the integration test command of that package (`swift test --package-path IntegrationTests --filter SubagentSessionsTests`). All pass.
- [ ] Run `swift test` at the root. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents