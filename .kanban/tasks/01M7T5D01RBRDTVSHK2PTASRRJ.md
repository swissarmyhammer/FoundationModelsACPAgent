---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: A cancelled scripted pass stops before its next step
---
Found during ^dxtwmw0.

`ScriptedSessionBackend.play` does not check cancellation between steps. Only the gate, hold and tool-body waits stop on a cancel. The `acp-agent-stub` container has no observer, so `turn?.takeAgain()` does not throw either.

When Router stops a model call at a tool result (compaction yield, no-op stop), it cancels the stream task. The old backend can then continue: it appends the `.toolOutput` entry and plays the next step, for example a second `agents` tool call, on the old backend. The new backend then also plays that step.

## Change
- `play` checks `Task.checkCancellation()` before each step.

## Tests
- A pass whose task is cancelled during the body of its first tool call does not invoke the tool of its second step.

#bug #scripted