---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: A failed turn builds its error message and then throws it away, so `_error` never says why
---
## The problem

A turn that fails reports the bare word `_error`, and the cause is lost. The
message is built, and then the mapping drops it.

`Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:46` holds the case
WITH the message:

```swift
case failed(message: String)
```

Lines 350 and 353 fill it from the real error:

```swift
return .failed(message: String(describing: modelError))
return .failed(message: String(describing: error))
```

And line 278 throws it away:

```swift
case .failed: .unknown(unmappedStopReasonValue)   // "_error"
```

The message is never read. No other line of the module uses it.

## What it costs

Two of the first five instances of the run of 2026-09-13 stopped with
`_error`:

| Instance | Agent seconds | Was the cause visible? |
|---|---|---|
| `django__django-13925` | 22 | Yes, but only because the `skills` TOOL recorded its own failure |
| `django__django-13964` | 49 | NO. Nothing says why |

The transcript of `django__django-13964` holds 17 lines. Every tool call in
it SUCCEEDED: two `runCode` operations and two shell commands, all with
`outcome: succeeded` and exit code 0. Then the turn stopped. The file has no
`toolCalls` entry, no `reasoning` entry, one empty `response`, and no error
of any kind.

So an instance died, it made no patch, and the harness, the transcript and
the record row together cannot say what happened.

## The work

- Carry the message of `.failed` to the wire. The `_`-prefix extension rule
  permits a value, so the stop reason can hold the cause, or a `session/update`
  beside it can.
- The harness must keep it. `swebench_record.py` has `stop_reason`, and a row
  that stops with `_error` must also hold the message. Add one name, in the
  shape of `env_reason`, which does the same for the environment step.

## When it is complete

- A turn that fails names its cause on the wire.
- The record row of an instance that stopped with `_error` holds that cause.
- A person can read the record of a run and say why each instance made no
  patch, with no need to read a transcript.

Related: [[the-skills-tool-fails-when-called-and-it-takes-the-whole-turn-down-with-it]]
#bench