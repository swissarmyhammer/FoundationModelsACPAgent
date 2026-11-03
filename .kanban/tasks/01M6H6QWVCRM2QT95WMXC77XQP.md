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
position_column: todo
position_ordinal: '9180'
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
- [ ] With `ACP_AGENT_STUB_SCRIPT` set to a file of the format above, a spawned `acp-agent` runs a root session whose first pass calls the `agents` tool; the child session runs its own scripted passes, and the grandchild too.
- [ ] A `gate` step holds the pass until the file exists or the pipe gets a byte, and a process kill during the gate leaves the run interrupted.
- [ ] A session that matches no entry echoes as before; with the variable unset nothing changes.
- [ ] A bad file (not JSON, unknown step) stops the stub path with a clear error on stderr, never a silent echo.
- [ ] One implementation of the scripted pass steps is used by the in-process tests and the stub path.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ScriptedStubModelTests.swift`: the parse of the file (each step, errors), the match by first prompt, passes in order, the gate.
- [ ] An IntegrationTests test that spawns the real binary with a script (root calls the `agents` tool, child answers) and checks the final text and the nested tool call.
- [ ] Run `swift test --filter ScriptedStubModelTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents