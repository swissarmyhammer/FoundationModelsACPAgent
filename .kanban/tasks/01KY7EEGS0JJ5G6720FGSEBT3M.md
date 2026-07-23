---
depends_on:
- 01KY7EDAAEV7M16J19CESQ54ZR
- 01KY7EDW19VD4WHHX8K612FMY1
- 01KY7EDW27992S3HF62045QR29
- 01KY7EDW2P2WR8QKN8BAX6SDNT
position_column: todo
position_ordinal: '8780'
title: 'The Agent conformance: ACP methods over Router sessions'
---
Plan §9.1 (the conformance, post-rename per 4axzgqm). Implements the wire package's Agent protocol: initialize (capabilities: text prompts + session management on; authenticate/logout/modes/fs/terminal off per the peering table); session/new(cwd) → per-cwd config layer + roster + instructions → router.makeSession; session/prompt → dispatch (commands) else session turn, pending request resolves with StopReason at turn end; Router's rich event stream → session/update mapping (textDelta → agent_message_chunk, reasoningDelta → agent_thought_chunk, toolCall/toolStatus → tool_call/tool_call_update with correlation-id fidelity, usage updates); session/cancel; list/resume/delete/close over the location policy + Router restore (replay from FULL history, live session from newest checkpoint — two transcripts, deliberately); available_commands_update from the registry; multi-session with profile-collision policy (project layer naming a different model: warn, keep resident). Cross-repo: wire package (FoundationModelsACP), Router 46adpch (rich stream) + 8213x39 (auto-compaction).