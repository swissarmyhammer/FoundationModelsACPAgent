---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Design: send agentPath and source of an elicitation to the client in the _meta of elicitation/create'
---
Design only. Do not write code before the step lead accepts this design. For AgentViewKit task 39: each card header shows who asks (agent path and source).

## Facts
- Extras 4820dfa: `ElicitationRequest.agentPath: [String]` and `source: String?`. `relayed(by:askedBy:)` puts the agent at the FRONT of the path, and sets `source` only when it is nil (`source ?? tool`).
- Router e2688ac2 `SubagentQuestionRelay.sendUp` calls `request.relayed(by: agentName, askedBy: event.tool)`. `agentName` is the name of the CHILD agent. Router adds no root name. Thus a question of the agent `reviewer` arrives at the root with `agentPath == ["reviewer"]`, not `["root", "reviewer"]`. A question of the root session has an empty path.
- ACP `CreateElicitationRequest` has `meta: JSONValue?` (the `_meta` of the request). It has no other field for this.
- `OperationEvent.tool` is the tool of the `ToolContext` of the run. For a `runCode` run it is `runCode`.
- Multitool 9fdea0f (`MCPServer+Elicitation.swift`) makes the `ElicitationRequest` of an MCP server question with no `source`, and asks through the `ToolContext` of the `runCode` call. Thus the event tool of an MCP server question is `runCode`, and the server name is lost.
- This agent already puts one plain key in a `_meta`: `missingTools` in the `session/resume` response.

## Design
1. Key names. Two plain keys in the `_meta` of `elicitation/create`, with the same names and JSON shapes as the Extras fields:
   - `agentPath`: array of strings. The order goes from the agent nearest the user to the agent that asked. The key is present only when the path is not empty.
   - `source`: string. The key is present only when there is a source that is not empty.
   - When neither key is present, `_meta` is omitted (it is not an empty object).
   - Example: `{"_meta": {"agentPath": ["reviewer"], "source": "runCode"}, "message": ..., "mode": "form", ...}`
2. The root level. The agent puts nothing in the path for the root session, and it does not add a root name. An omitted `agentPath` means "the session of this ACP connection asked". The client shows its own label for that (AgentViewKit can show `root`, so `root › reviewer` is the label of `["reviewer"]`). Reason: the root has no agent name in Router, and a name made up by the agent would differ from the client's session title.
3. The source. `source = request.source ?? event.tool`, from the `OperationEvent` that carried the question to the relay:
   - A `runCode` question of the root session: `request.source` is nil, so `source` is the event tool, `runCode`.
   - A relayed question of a child: Router already set `source` to the tool of the run in the child (`runCode`). The agent keeps it.
   - An MCP server question: this needs a Multitool change (follow-up card on the Multitool board, to discuss first, see below). `MCPServer+Elicitation` sets `source` to the server name when it makes the `ElicitationRequest`. Then the relay of every level keeps it, and the agent sends it. Until that change lands, an MCP server question shows `runCode`.
4. Code shape (ACPAgent only, no public API change): `ElicitationRelay.wireRequest(for:sessionId:toolCallId:)` gets one more internal parameter, `tool: String` (the event tool), and sets `meta`. A new internal enum `ElicitationAskerMeta` holds the two key names and builds the `_meta` value, as `SessionResume` holds `missingToolsMetaKey`. Dependency: Extras at or after 4820dfa (the package follows Extras main).
5. No change to the replay and the history: `elicitation/create` is a live request, and the agent does not record it in the ACP history.

## Tests (fixed order; no time limit, sleep, poll or retry; each test fails on the old code, because the old `wireRequest` sets no `meta`)
Unit tests on the static `wireRequest` (pure functions, no wire):
1. A form question of the root session with event tool `runCode`: `_meta == {"source": "runCode"}`, and there is no `agentPath` key.
2. The same request in URL mode: the same `_meta`. (One parameterized test over the two modes.)
3. A question that `relayed(by: "reviewer", askedBy: "runCode")` made: `_meta == {"agentPath": ["reviewer"], "source": "runCode"}`.
4. Two levels, `relayed(by: "linter", ...)` and then `relayed(by: "reviewer", ...)`: `agentPath == ["reviewer", "linter"]`.
5. A request with `source: "github"` and event tool `runCode`: `source == "github"` (the source of the request wins over the event tool).
6. An empty event tool and no request source: no `source` key; with no path, `meta == nil`.
7. The encoded wire JSON: `_meta` is a member of the request object, and `message`, `mode` and the mode payload are the same as before.
Wire test:
8. With `ScriptedPromptFixture` (`tapsAgentWire: true`), a `runCode` snippet asks one question. The raw `elicitation/create` line that the client gets has `_meta.source == "runCode"` and no `agentPath`. The fixed point is the pending question at the client (`ElicitationWait.firstPendingElicitation`).
A wire test with a real child agent is for the Agents integration tier, not for this card.

## Follow-ups (not in this card)
- Multitool: set `source` to the server name in `MCPServer+Elicitation` (discuss with the step lead first; it is a change in a family package).
- ACPClient: expose `agentPath` and `source` on `PendingElicitation`, read from `_meta` (step lead).
- AgentViewKit task 39: show them in the card header (step lead).
- If the step lead wants `["root", "reviewer"]` on the wire, the decision is where the name `root` comes from (agent or Router). #elicitation-phase-4
## Done (design accepted by the step lead)
- [x] `ElicitationAskerMeta`: the keys `agentPath` and `source` in the `_meta` of `elicitation/create`, each only when not empty; no key gives no `_meta`. `source = request.source ?? event.tool`.
- [x] `ElicitationRelay.wireRequest(for:sessionId:toolCallId:tool:)`: the new internal `tool` parameter; `relay(_:on:)` passes `event.tool`.
- [x] Tests: `ElicitationAskerMetaTests` (root question in form and URL mode; one level; two levels; the request source wins; no path and no source gives no `_meta`; the encoded members; the wire line of a `runCode` question). With the `_meta` removed, six of the seven tests fail. `aQuestionWithNoPathAndNoSourceHasNoMeta` also passes on the old code, because it holds the "no key, no `_meta`" rule.
- Not pushed: the step lead batches this with the ACP cancel-reason part. One full run before the push.
- [x] Same push window (step lead): the cancel reason. Each `elicitation/create` gets its own `OutboundCancellation` (FoundationModelsACP 97a9d5e). `end(_:)` sets `_meta.reason` to the reason of the end (else its action), and `drainOpenRoundTrips()` sets "the session ended", before the cancel. Test `ElicitationCancelReasonTests` fails with the `setMeta` removed. One full run: 974 tests in 108 suites, green.
