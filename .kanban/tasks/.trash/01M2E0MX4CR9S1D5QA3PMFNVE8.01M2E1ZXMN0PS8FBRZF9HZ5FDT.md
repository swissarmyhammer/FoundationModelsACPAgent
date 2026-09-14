---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Router: a live transcript records no tool input, so a failed instance cannot be read'
---
## The problem

A transcript of a LIVE run holds the output of each tool call and never the
input. You can see what a tool answered. You cannot see what the model asked.

Measured on the run of 2026-09-13, instance `django__django-13447`. Each entry
of the file holds these keys and no others:

```json
{"correlationID": "...", "detail": "...", "kind": "progress",
 "op": "runCode", "tool": "runCode"}
```

The `execute` entries are the same shape. They hold `commandID`,
`durationMs`, `exitCode`, `lines` and `output`. The command string is absent.

So after a run gives an empty patch, nobody can say what the model tried.
That was the first question of the run of 2026-09-11, and it is still not
answerable.

## Why the card that closed this did not close it

Card `01M20G2K4P99H1MBE5TSG4T8CM` is in `done`. Its commit `f67ca45` added
tests and documents only, and no product code. The proofs use the SCRIPTED
backend. A scripted backend grows its transcript, so a `toolCalls` entry
appears there. The live backend does not.

## Where the input is lost

Two producers write transcript lines:

1. `RoutedSessionActorRecording.swift:152` `recordTranscriptDelta` diffs the
   entries of the backend at the end of a turn. Its mapper DOES carry the
   arguments, at `TranscriptEntryMapper.swift:394`:
   `ToolCallPayload(id:toolName:argumentsJSON: call.arguments.jsonString)`.
   But `LiveModelLoader.swift:280` reads `Array(liveSession.transcript)`, and
   with the dynamic tool mounting of `searchTools` that transcript keeps only
   the rewritten `instructions` entry. So the diff never sees a `.toolCalls`
   entry, and this path writes nothing.
2. `RoutedSessionActorRunJournal.swift:57` `makeRunEventPartial` writes one
   synthetic entry for each operation event, during the turn. This is the path
   that runs live. It carries `OperationEvent`, and that type structurally
   holds no arguments: `OperationEvent.swift:21-44` has `tool`, `op`,
   `correlationID`, `kind`, `detail`, `outcome`, `elicitation`.

`ToolInvocationRecord` could carry it, but `RoutedSessionActorRunJournal.swift:104`
says it is never journaled, and that type holds no arguments either.

## The work

The fix is in the `FoundationModelsRouter` dependency, and not here. This
repository owns the READ side of transcripts only. The pin is `d469aa0` at
`Package.resolved:73`.

Two places answer it:

1. `LiveModelLoader.swift:280` -- let the transcript of the live backend grow
   with the prompt, the tool calls and the response. This repairs three
   symptoms together: the absent source, the empty `response` lines, and the
   `divergence` marks.
2. `RoutedSessionActorRunJournal.swift:57` -- journal the tool input beside
   the first event of an operation. This is smaller, and it needs a new
   carrier, because `OperationEvent` cannot hold the input.

## When it is complete

- A live run writes the JavaScript source of each `runCode` call.
- A live run writes the command string of each shell call.
- A person can read one instance of a bench run and say what the model tried.
#bench