---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20mhs36vxg44cczmj0j0qg2
  text: |-
    ### The evidence on this card came from the wrong model — 2026-09-08

    This card says every `runCode` snippet fails to parse. That is true of
    the recorded run, and the run drove a model this package does not ship.

    Measured from the recorded entries of the 2026-09-07 run:

    | slot | model | entries |
    |---|---|---|
    | standard | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | 519 |
    | flash | `mlx-community/Qwen3-4B-4bit` | 168 |

    The standard slot writes the snippets. `PythonCLIEvaluation.swift:69`
    pinned it at `Qwen2.5-Coder-32B-Instruct-4bit`, and the pin stayed after
    `^k4rq6ab` moved the shipped default to `mlx-community/Qwen3.8-27B-4bit`.
    So every recorded run measured a stale model.

    `Unexpected token '('` from a 2024 coder model is a reading of that
    model. It is not evidence about this agent.

    **Corrected.** `evalStandardModel` is now
    `mlx-community/Qwen3.8-27B-4bit`, which is
    `ProfileConfiguration.defaultStandard`. The doc comment states the rule:
    an evaluation of the agent must drive the model the agent ships, or it
    measures a product nobody uses. `swift build --package-path IntegrationTests --build-tests`
    is clean.

    **This card now waits for new evidence.** Run the eval on the shipped
    model and read the result:

    - If the snippets parse, this card closes. The failure was the stale
      pin, and the agent was never at fault.
    - If the snippets still fail to parse, the card stands, and the evidence
      is at last about the product. Then read the source and name the true
      syntax cause.

    Do not work the "correct the parse-failure message" items until that run
    says which. `^jz016kq` and the two Router cards are what make the source
    readable, whatever the answer.
  timestamp: 2026-09-08T13:50:33.062708+00:00
- actor: claude-code
  id: 01m21f2x1wbyww0c8h63232k44
  text: |-
    ### Correction — the premise of this card is no longer true

    This card says "the agent runs a turn, calls tools many times, and writes no file", with 0 runs that reported `complete` over 387 `runCode` segments.

    That measurement came from the 2026-09-07 run, which used a stale model pin (`Qwen2.5-Coder-32B-Instruct-4bit`). The "Unexpected token '('" failures were a reading of THAT model.

    Measured on 2026-09-08, after the pin moved to `mlx-community/Qwen3.8-27B-mxfp4` (card `^s0bw5cv`) and the two ceilings were corrected (card `^ec8hn3z`), one tier-4 sample gives:

    ```
    stop=endTurn turns=1 toolCalls=38 tokens=146655/262144 elapsed=658s
    model=mlx-community/Qwen3.8-27B-mxfp4
    pytest=PASS cli=PASS files=PASS traffic=PASS
    ```

    One turn, 38 tool calls, the files on disk, pytest green. The end-to-end failure this card reports does not happen any more.

    The card is not empty, but its work is now different. What stays true and is still of use:

    - A snippet that does not parse must get back the failing line and the token, not only "Fix the snippet". Shape 2 (the unknown-tool message) recovers because it names the fix; shape 1 does not.

    Re-write this card around that message quality, with a new measurement, before you start work on it. Do not use the 2026-09-07 numbers.
  timestamp: 2026-09-08T21:34:17.148560+00:00
depends_on:
- 01M20G2K4P99H1MBE5TSG4T8CM
position_column: todo
position_ordinal: 9d80
title: Every runCode snippet fails, so the agent does no work end to end
---
### What

The agent runs a turn, calls tools many times, and writes no file. This
is the end-to-end failure, and it is not a scoring bar.

Measured on the tier-4 eval run of 2026-09-07, over every transcript in
`/private/tmp/PythonCLIEval-user-E6179229-.../transcripts/`:

| reading | count |
|---|---|
| `runCode` tool-output segments | 387 |
| `execute shell` tool-output segments | 22 |
| pending completion tokens issued | 130 |
| runs that reported `complete` | **0** |

The grader of one sample says the same in its own words:

```
sample repeat: stop=endTurn turns=4 toolCalls=10
  files=FAIL(missing files: pyproject.toml, repeat_cli.py, tests/test_cli.py)
  pytest=FAIL(no venv interpreter at .venv/bin/python)
```

Four turns, ten tool calls, no files.

### Two failure shapes, both in the record

**1. The snippet does not parse.** The result segments read:

```
The snippet failed: Unexpected token '(' (line 42)

Fix the snippet and call runCode again.
```

The same message stands at line 42, then line 56, then line 71. The
snippet gets LONGER each time, so the model adds code instead of
correcting the parse error.

**2. The snippet names a tool that is not there.**

```
The snippet failed: tools.listFiles is not a function.
(In 'tools.listFiles('.')', 'tools.listFiles' is undefined) (line 25)

tools.listFiles does not exist. Call tools.files.read instead, or one
of the others listed.
```

This correction is good: it names the true tool and gives the full
declarations back. Shape 1 gives no such help — it says only "Fix the
snippet", and the model does not recover.

### What to do

First **read the snippets**. `^sg4t8cm` makes them readable; this card
depends on it.

Then answer these, with evidence and not by guessing:

- What syntax does the model write that JavaScriptCore refuses? Find the
  true token at the true line.
- Is it a dialect the interpreter could accept — for example a
  construct a newer JavaScriptCore takes — or is the model wrong?
- Does the parse-failure message give the model enough to correct
  itself? Shape 2 recovers because the message names the fix. Shape 1
  gives "Fix the snippet" and nothing else. Show the failing line and
  the token, as shape 2 shows the tool list.
- Do `BuiltinInstructions` teach the dialect the interpreter accepts?
  `BuiltinInstructions.swift:51` speaks of the snippet and `runCode`.

- [ ] Read the failing snippets, and name the true syntax cause
- [ ] Make the parse-failure message name the line and the token
- [ ] Correct the cause: the instructions, the interpreter, or both
- [ ] Prove one whole task ends with the files on disk

### Acceptance Criteria

- [ ] A `runCode` snippet that fails to parse gets back the failing
      line, the token, and one instruction that names the fix.
- [ ] The recorded cause of "Unexpected token '('" is written on this
      card, with the snippet line that produced it.
- [ ] A driven end-to-end task writes its files to disk.
- [ ] `swift test` at the root stays green.

### Tests

- [ ] A test drives a `runCode` snippet that cannot parse, and reads
      back a message that names the line and the token.
- [ ] A test drives a snippet that DOES parse and writes a file, and
      asserts the file is on disk with its content.
- [ ] The present tier-2 `runCode` proofs still pass.

### Not in this card

No benchmark, and no timing. `^k71g431` is archived.
