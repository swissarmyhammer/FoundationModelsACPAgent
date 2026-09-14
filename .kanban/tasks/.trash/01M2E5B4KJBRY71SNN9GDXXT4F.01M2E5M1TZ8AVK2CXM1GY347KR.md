---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: The agent writes the fix into its reasoning, never applies it, and reports end_turn
---
## The problem

An instance spends its whole turn in reasoning, writes the fix as TEXT inside
that reasoning, never calls a tool to change a file, and then reports
`end_turn`. The harness records a normal completion with an empty patch.

`django__django-14017`, instance 7 of the run of 2026-09-13. 773 s of agent
time, and no patch.

| Measure | Value |
|---|---|
| `runCode` calls | 8 |
| `wait` calls | 9 |
| `searchTools` calls | 2 |
| `response` entries | 19, and ALL 19 are empty |
| `reasoning` entries | 19, and none is empty |
| The last reasoning block | 29894 characters |

That last block holds the model at work on the fix, in prose and in Python.
It quotes and rewrites `Q.__init__` and `Q._combine` of
`django/db/models/query_utils.py`, and it ENDS IN THE MIDDLE OF A SENTENCE:

```
    def _combine(self, other, conn):
        if not isinstance(other, Q):
            return NotImplemented
        # If the other Q() is empty, ignore it and just use
```

So the agent did the work. The answer never reached the disk.

`django__django-13710`, instance 2, is the same fault with a different face:
19 empty responses there too, and a final reasoning block that repeats two
sentences again and again until the turn ends.

## Why the guard does not catch it

`EventProjection.swift:141` holds the guard:

```swift
var generatedNothing: Bool {
    !sawOutput && sawUsageReport && tokensOut == 0
}
```

It asks for `tokensOut == 0`. A turn that writes 29894 characters of reasoning
has a large `tokensOut`, so the guard cannot fire. `sawOutput` is true as well,
because a tool call sets it (lines 163 to 237). So a turn that reasons for
thirteen minutes and changes nothing reports the same `end_turn` as a turn
that fixed the bug.

## The work

Three parts, and each stands alone:

1. **Report it honestly.** A turn that ends with no response text and no file
   change is not an `end_turn`. The `_`-prefix extension rule already carries
   `_no_output` and `_stalled`. This condition needs a value of its own, and
   the guard must not ask for zero tokens.
2. **Find why the response is always empty.** 19 of 19 here, 36 of 36 in
   instance 2. The model reasons and calls tools, and it never emits one
   response. A card for this is in `done` already, and this run shows it is
   not fixed.
3. **Tell the agent to apply the change.** The reasoning of this instance ends
   mid-sentence, which reads like a ceiling on the reasoning. An instruction
   to make the edit with a tool FIRST, and to explain after, would put the
   work on disk before any limit is reached.

## When it is complete

- A turn that changes no file does not report `end_turn`.
- The record row of such an instance says what happened.
- `django__django-14017` and `django__django-13710` make a patch.

Related: [[bench-tell-the-agent-to-change-the-source-only-so-it-stops-writing-docs-release-notes-and-tests]]
and [[a-failed-turn-builds-its-error-message-and-then-throws-it-away-so-error-never-says-why]]
#bench