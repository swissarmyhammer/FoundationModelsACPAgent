---
comments:
- actor: claude-code
  id: 01m6hcxam9c490zs06kyq2mscn
  text: 'implement - changed. Branch worktree-agent-afd80ab03c692a6dd. The scripted pass steps now live in the library (ScriptedPassStep, ScriptedSessionBackend, ScriptedPlaybook, ScriptedLLMContainer, ScriptedHold). The test support keeps only the recorder, the delivery hooks and an observer. The stub path reads ACP_AGENT_STUB_SCRIPT (ScriptedStubScript parses the JSON, a bad file throws ScriptedStubScriptError before the wire opens). New step: gate(path) waits for a file or one byte of a named pipe. Tests: ScriptedStubModelTests (23 pass), IntegrationTests ScriptedStubProcessTests (2 pass), root swift test 1343 pass, 1 known issue. Notes: the worktree resolved a newer Router, so Package.resolved was copied from the main checkout. CloseCountingRoutedSession got the missing completeClaimedRun forwarder, because the test target did not build without it.'
  timestamp: 2026-11-03T19:06:55.497283+00:00
- actor: claude-code
  id: 01m6hd4zakx0rh8920fpm76kyk
  text: 'Landed on origin/main as commit 753dd02. Root tests: 136 passed. Integration ScriptedStubProcessTests: 2 passed.'
  timestamp: 2026-11-03T19:11:06.067767+00:00
- actor: claude-code
  id: 01m6j6v9v48hzsjcc4jqaay24e
  text: |-
    ### implement — no-change
    - evidence: All items verified against the code from commit 753dd02 and later commits. ScriptedStubModelTests: 26 pass (swift test --filter ScriptedStubModelTests). IntegrationTests ScriptedStubProcessTests: 2 pass (root calls the agents tool; bad script stops the run with an error). The stub binary acp-agent-stub reads ACP_AGENT_STUB_SCRIPT (ScriptedStubScript, ScriptedPassStep, ScriptedPlaybook: one implementation). All 8 checkboxes set in the .md file. No file was changed in the source.
    - next: /review
  timestamp: 2026-11-04T02:40:12.132961+00:00
- actor: claude-code
  id: 01m6j756eb89sqhbc5qfb9mxhf
  text: |-
    ### review — findings
    - evidence: 4 findings (4 confirmed, 1 refuted). IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ScriptedStubProcessTests.swift:68, Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift:189, Sources/acp-agent/AgentComposition.swift:118 (two findings).
    - scope: review sha 753dd02~1..753dd02.
    - next: fix each open finding in the dated Review Findings section. The task stays in review.
  timestamp: 2026-11-04T02:45:36.331735+00:00
- actor: claude-code
  id: 01m6j75sp1bsndq1249dhkn40x
  text: |-
    ### finish iteration 1 — findings
    - implement: no-change — all 8 items already done by commit 753dd02 and later commits
    - test: not run — no source change; ScriptedStubModelTests 26 and ScriptedStubProcessTests 2 passed in the implement step
    - commit: 6d2dd22 (kanban files only)
    - review: findings — 4 open on range 753dd02~1..753dd02: ScriptedStubProcessTests.swift:68, ScriptedSessionBackend.swift:189, AgentComposition.swift:118 (two findings)
    - note: the two findings at AgentComposition.swift:118 differ on stubChunkGate (leave unchanged / must call the helper). The file has moved since 753dd02. Verify each finding against the current code first.
    - next: implement works the open findings
  timestamp: 2026-11-04T02:45:56.033793+00:00
- actor: claude-code
  id: 01m6j783n7p1r2s7eycnsagpm9
  text: |-
    ### implement — changed
    - evidence: Finding 1 (ScriptedStubProcessTests.swift:68): the copy no longer exists; both suites call TierThreeFixture.writeStubScript. Findings 3 and 4 (AgentComposition.swift:118): stubScript() and stubChunkGate() no longer read the environment; both read the model choice (an enum), so no shared env helper is needed and no copy of the body remains. Finding 2 (ScriptedSessionBackend.swift:189): still held. Added ScriptedSessionBackend.makeSibling(of:tools:instructions:seededEntries:observer:); the private makeSibling(seededEntries:) and ScriptedLLMContainer.makeBackend both call it. Files: Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift, Sources/FoundationModelsACPAgent/Configuration/ScriptedPlaybook.swift. Tests: swift test --filter ScriptedStubModelTests 26 pass; IntegrationTests --filter ScriptedStub 2 pass. All 4 boxes set.
    - next: /review
  timestamp: 2026-11-04T02:47:11.783906+00:00
position_column: doing
position_ordinal: '8380'
title: 'Scripted stub model for the spawned acp-agent: ACP_AGENT_STUB_SCRIPT'
---
## What
The spawned `acp-agent` binary needs a scripted stub model, so that a test over the process boundary can make a session call the `agents` tool and nest. Today the stub paths are: `ACP_AGENT_STUB_MODEL=1` (EchoSessionBackend: answers each prompt with the prompt, no tool call) and `ACP_AGENT_STUB_CHUNK_GATE` (a named pipe that holds the echo chunk by chunk). The scripted pass steps (`ScriptedPassStep`: `.toolCall(name:argumentsJSON:)`, `.holdUntilReleased`) exist only in the in-process test support. The client package needs this for its end-to-end acceptance test of nested sessions and of a kill and resume (client session request, 2026-11-03).

DESIGN (decided by the coordinator, so the client can write its test now):
- Environment variable `ACP_AGENT_STUB_SCRIPT`: the absolute path of a JSON file. When it is set, the agent uses the stub path (as with `ACP_AGENT_STUB_MODEL=1`) and the scripted model. It is read only on the stub path, like the chunk gate. It must have no effect when it is not set.
- File format (JSON):
  `{ "sessions": [ { "match": { "promptContains": "<text>" }, "passes": [ [ <step>, ... ], [ <step>, ... ] ] } ] }`
  A session matches by the text of its FIRST prompt (the root: the prompt of the client; a child or grandchild: the first message of its run, which the `agents` tool builds from its `prompt` argument). The first matching entry wins; a session that matches nothing echoes as today. `passes` is the list of the model passes of that session, used in order, one for each model call (a pass that calls a tool is followed by the pass that sees the tool output). After the last pass the session echoes as today.
- Steps: `{"text": "<delta>"}`, `{"reasoning": "<text>"}`, `{"toolCall": {"name": "agents", "arguments": { ... json ... }}}` (the arguments are a JSON object; encode them as the argumentsJSON), and `{"gate": "<path>"}`: the pass waits until the file at that path exists or a byte can be read from the named pipe, like the chunk gate. A gate step lets a test stop a run in the middle, so it can kill the process while the run works.
- The agent definitions (`AGENT.md`) are files in the test project folder (the `agents` dotfolder), written by the test; the stub model serves every slot, so the child and grandchild sessions use the same stub and match by their own first prompt.
- Move or share the scripted pass machinery (`ScriptedPassStep`) so the in-process test support and the stub path use one implementation; no copy. One code path.

## Acceptance Criteria
- [x] With `ACP_AGENT_STUB_SCRIPT` set to a file of the format above, a spawned `acp-agent` runs a root session whose first pass calls the `agents` tool; the child session runs its own scripted passes, and the grandchild too.
- [x] A `gate` step holds the pass until the file exists or the pipe gets a byte, and a process kill during the gate leaves the run interrupted.
- [x] A session that matches no entry echoes as before; with the variable unset nothing changes.
- [x] A bad file (not JSON, unknown step) stops the stub path with a clear error on stderr, never a silent echo.
- [x] One implementation of the scripted pass steps is used by the in-process tests and the stub path.

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/ScriptedStubModelTests.swift`: the parse of the file (each step, errors), the match by first prompt, passes in order, the gate.
- [x] An IntegrationTests test that spawns the real binary with a script (root calls the `agents` tool, child answers) and checks the final text and the nested tool call.
- [x] Run `swift test --filter ScriptedStubModelTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-03 20:40)

> Scope: `review sha 753dd02~1..753dd02` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 0 not reviewed.

- [x] `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ScriptedStubProcessTests.swift:68` `reuse/reuse` — The new writeScript(_:label:) repeats a helper that already exists. It makes a resolved directory, writes the script text to script.json, and returns the file URL. The copy is exact, so the same behavior now lives in two test files. Move one shared script-writing helper into the integration support folder (for example TierThreeFixture) and call it from ScriptedStubProcessTests and ScriptedElicitProcessTests, instead of keeping a copy in each suite.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ScriptedSessionBackend.swift:189` `duplication/duplication` — `makeSibling(seededEntries:)` builds a `ScriptedSessionBackend` with the same five-argument call that `ScriptedLLMContainer.makeBackend(tools:instructions:seededEntries:)` uses. Both pass `playbook.makeSibling()`, the tools, the instructions, the seeded entries and the observer. A change to the backend's init arguments must be made in both places. Move the construction into one place. For example, give `ScriptedSessionBackend` a static factory `make(playbook:tools:instructions:seededEntries:observer:)` and have both `makeSibling(seededEntries:)` and `ScriptedLLMContainer.makeBackend` call it. The two call sites then differ only in where their values come from.
- [x] `Sources/acp-agent/AgentComposition.swift:118` `duplication/duplication` — The new `stubScript(environment:)` repeats the body of the existing `stubChunkGate(environment:)` word for word: read an environment variable, return nil when it is absent or empty, otherwise return the value. Only the variable name differs. The two copies can drift apart, for example if the empty-value rule changes for one variable and not the other. Extract one helper, for example `static func nonEmptyValue(of name: String, in environment: [String: String]) -> String?`, and make `stubScript(environment:)` call it with `stubScriptVariable`. Leave `stubChunkGate(environment:)` unchanged in this change. Converting it to the same helper is a separate task, because it is outside this change.
- [x] `Sources/acp-agent/AgentComposition.swift:118` `reuse/reuse` — The new stubScript(environment:) repeats the body of stubChunkGate(environment:): it reads one environment variable and returns nil when the value is empty. This is a near-match that was copied, not extended. A future change to the empty-value rule must be made in two places. Add one private helper, for example nonEmptyValue(of variable: String, in environment: [String: String]) -> String?, and have stubScript and stubChunkGate both call it. Keep the variable names as the parameters.
