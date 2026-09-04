---
assignees:
- claude-code
depends_on:
- 01M1MP01P7SV7C2S0S8QZ0A60T
position_column: todo
position_ordinal: '8780'
title: 'run: the prompt source table and the stdout contract'
---
## What

cli-plan.md §5.5 and §5.6, in `Sources/acp-agent/RunCommand.swift` and a
new `Sources/acp-agent/AnswerWriter.swift`.

**Where the prompt comes from.** In `acp` mode stdin is the wire, and
that mode never looks at stdin for a prompt. In `run` mode:

| Condition | Result |
|---|---|
| A prompt argument | Use it. |
| No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
| No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
| The prompt is `-` | Read the prompt from stdin, a terminal included. |

Detect a terminal with `isatty(STDIN_FILENO)`. This gives
`echo "hello" | acp-agent`, which is what a person expects.

**stdout.** `AnswerWriter` writes each `agent_message_chunk` to file
descriptor 1 as it arrives, and it flushes each one. A local model is
slow, so a person must see the answer grow.

- Write the text **verbatim**. Add no trailing newline, and add no
  color, in a terminal and in a pipe alike. The output is data, and a
  rule that changes with a terminal cannot be tested byte for byte.
- stdout gets nothing more. Not a session id, not a token count, not a
  stop reason. Those go to stderr.

- [ ] The four rows of the prompt-source table
- [ ] `AnswerWriter`: write and flush per chunk, verbatim
- [ ] Move every other message off stdout

## Acceptance Criteria

- [ ] `echo "hi" | acp-agent` reads the prompt from stdin.
- [ ] `acp-agent run` with a terminal stdin prints the usage to stderr
      and exits 2, with stdout empty.
- [ ] `acp-agent run - < file` reads the file.
- [ ] `acp-agent run "hi" > out.txt` gives a file whose bytes equal the
      concatenated chunks, with nothing added and nothing removed.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/PromptSourceTests.swift`: one
      test per row of the table, with a `Pipe` for the non-terminal
      cases.
- [ ] `Tests/FoundationModelsACPAgentTests/AnswerWriterTests.swift`:
      given chunks `["a", "b", "c"]`, the captured stdout is exactly
      `abc` — no newline, no escape sequence.
- [ ] An integration test with the scripted model asserts stdout is
      byte-identical to the concatenation of the scripted chunks.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.