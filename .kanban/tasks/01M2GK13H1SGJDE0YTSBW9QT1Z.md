---
position_column: done
position_ordinal: e280
title: A truncated turn reports end_turn
---
## The problem

A turn that the model cut off in the middle of a thought reports `end_turn`,
the stop reason of a turn that finished its work. The bench then records a
silent truncation as a true failure of the agent to solve the problem.

Measured in the SWE-bench run of 2026-09-14. Three instances of 16:

| instance | tokensOut | agent seconds | tool calls | stop reason |
|---|---|---|---|---|
| django__django-13925 | 8192 | 231 | 0 | `end_turn` |
| django__django-13964 | 8192 | 228 | 0 | `end_turn` |
| django__django-14016 | 8192 | 228 | 0 | `end_turn` |

Each transcript is 5 lines. One reasoning block of 30000 to 34000
characters, one empty response, and NO tool call. Each reasoning block stops
in the middle of a sentence, on a phrase such as "let me recall". The
`tokensOut` of each one is 8192 exactly, which is the ceiling of the
generation call.

`django__django-14016` made a patch in the run of 2026-09-12. The instance
is not the difficulty. The turn ran out of tokens while it was thinking.

## Why the rescue does not fire

`Agent/PromptTurn.swift:204` starts the turn at `TurnStop.completed`, and no
event of this turn changes it.

`PromptTurn.swift:231` holds the rescue for a turn that made nothing, and it
cannot fire here. `EventProjection.generatedNothing` asks for
`tokensOut == 0`. This turn made 8192 tokens. They were all reasoning, and
none of them reached the user or a file, but the count is not zero.

`PromptTurn.swift:271` then maps `.completed` to `.endTurn`.

`.maxTokens` is unreachable for this condition. `PromptTurn.swift:343-348`
makes it from `LanguageModelError.contextSizeExceeded` only, which is an
overflow of the INPUT context. That is a different budget.

## The work

Router must carry the fact first. That is the card
[[the-token-ceiling-is-a-constant-and-a-truncated-turn-is-silent]] in
`FoundationModelsRouter`. It derives the ceiling from the model and gives
the host a finish reason. This card has nothing to map until that lands, so
it depends on it.

Then, here:

1. Read the finish reason of the turn, and set the stop when it says the
   generation reached its ceiling.
2. Give it a wire value. `PromptTurn.swift:69-77` holds the `_`-prefix
   extension values already: `_error`, `_no_output`, `_stalled`. This
   condition needs one of its own, for example `_truncated`. It is NOT
   `end_turn`, and it is not the `max_tokens` of an input overflow.
3. Consider widening `generatedNothing`. A turn that made tokens, and made
   no tool call and no response text, generated nothing that the user can
   use. The `tokensOut == 0` test is too narrow to say so.

The bench reads the stop reason from the wire and writes it in the record
row of the instance, so no change is needed there. The row will say
`_truncated` on its own.

## When it is complete

- A turn that stops at the token ceiling reports a stop reason that is not
  `end_turn`.
- A test drives a backend that reports the truncation, and proves the wire
  value.
- A person who reads `bench/preds.runs.jsonl` can tell a truncated turn from
  a turn that finished and made no patch.