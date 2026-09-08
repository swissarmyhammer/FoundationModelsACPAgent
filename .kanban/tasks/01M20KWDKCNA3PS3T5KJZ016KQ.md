---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20ma6vb1kswwtrasek1vbw1
  text: |-
    ### The work moved to the Router board — 2026-09-08

    The user settled two points that decided where this belongs:

    1. **The transcript is append-only.** So the `instructions` entry at
       index 0 cannot have changed. The baseline check compares two readings
       of one unchanged entry and calls them different, so the reading is
       not stable. This is a check defect, not a data defect.
    2. **There is no case for discarding a transcript entry.** A transcript
       appends. The discard path must go away, not become conditional.

    Two cards now hold this, on `FoundationModelsRouter`:

    - `^cybh869` — "The transcript recorder discards a whole turn on
      divergence, and it must only append." This is the one that matters. It
      lands whatever the trigger turns out to be.
    - `^9hdy3hq` — "An append-only entry compares unequal on re-read, so the
      baseline check raises a false divergence." This stops the false alarm.

    This card keeps the agent-side half: when both Router cards land, prove
    from this package that a turn is recorded whole and that
    `SessionEvent.toolCall` reaches the wire. Until then it waits.

    **A retraction.** An earlier comment on `^sg4t8cm`, and my report to the
    user, said the discarded turns might cost the model its own history and
    so explain the failing snippets. That is probably wrong. `liveSession`
    is a `let`, made once and held, and the recorder reads its transcript as
    an observer. A lost recording does not erase the session's memory. So
    this defect HIDES the snippet failures; it does not cause them.
    `^95jyv07` stays a separate question.
  timestamp: 2026-09-08T13:46:25.003685+00:00
- actor: claude-code
  id: 01m214hq29zzk1b146ma4jnc49
  text: |-
    ### The agent-side verification — what I found and what I did

    **The Router half is in place.** The pin `cc51793` holds two corrections:

    - `a3612d3` encodes each persisted schema with sorted keys, so one
      unchanged tool definition encodes to the same bytes on two readings.
      The comment in `TranscriptEntryMapper.makeDeterministicEncoder()`
      names the cause: `GenerationSchema` encodes its objects from
      dictionaries, and a dictionary's iteration order changes between
      readings.
    - `efcf8d7` makes the recorder append-only. `TranscriptDiffer.partials`
      now records every entry the baseline does not hold, and the
      `divergence` value is only a marker. No turn is discarded.

    `TranscriptDiffer.divergence(from:in:)` also compares the payload of the
    BOUNDARY entry only. So a rewrite in the middle of the transcript is no
    longer reported, and a rewrite of the newest entry still is.

    **The harness could not prove the fact.** `ScriptedSessionBackend`
    synthesized `.toolCalls` and `.toolOutput` entries only. It made no
    `.instructions` entry, no `.prompt` entry and no `.response` entry, so a
    recording over it could not show a whole turn, and the unstable schema
    encoding was never exercised.

    **What I changed in this repository.**

    1. `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift` —
       the scripted backend now synthesizes the transcript shape of a real
       model session: one leading `.instructions` entry, made once in `init`
       from the session instructions and one `Transcript.ToolDefinition` per
       handed tool; one `.prompt` entry per generating call; the tool
       entries as before; and one `.response` entry for a play that reached
       the turn end. A failing or cancelled play appends no `.response`
       entry, as a real failed turn records none. `ScriptedLLMContainer`
       passes the instructions through, and the transcript factories seed
       the backend from the given transcript.
    2. `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift` —
       four proofs over one two-turn scripted session.

    The proofs read the recorded `transcript.jsonl` files from disk for the
    tool arguments, because Router keeps `TranscriptEntryPayload.toolCalls`
    internal. The typed `TranscriptEvent.merged` read answers the other
    proofs.

    **No sleep is added.** The suite waits on facts with the wait helpers
    that stand — `waitForIdle`, `waitForRecordedResponses` and
    `waitForAvailability`.
  timestamp: 2026-09-08T18:30:08.201671+00:00
- actor: claude-code
  id: 01m214j529xrzxs5zt4w73vg0v
  text: |-
    ### The red-green record, and the two failure experiments

    **The first run was red, and for the correct reason.** Before the
    backend change, the four proofs ran and the recording held no `prompt`
    and no `response` event:

    ```
    "the recording never reached 1 response event(s)"
    Expectation failed: prompts.count == 2   (prompts.count -> 0)
    Expectation failed: responses.count == 2 (responses.count -> 0)
    ```

    **Two proofs passed at once, and I say so plainly.** With the Router
    correction in place, proof 3 (the wire) and proof 4 (the count) passed
    in that first run, and proof 1 (no divergence) held over a recording
    that was empty of turns. So I broke each property on purpose to show
    that each proof can fail.

    **Experiment A — a rewrite in place of the newest entry.** I made the
    backend rewrite the previous `.response` entry, with its id unchanged,
    at the start of each turn. Result:

    ```
    Test "two turns record no divergence while the tool surface is
    unchanged" recorded an issue at TranscriptFidelityTests.swift:215:9:
    Expectation failed: run.eventsAfterSecondTurn.allSatisfy
    { $0.kind != .divergence }
    ```

    **Experiment B — no `.toolCalls` entry, the loss this card reports.** I
    made the backend skip the `.toolCalls` entry. Result:

    ```
    Test "one turn records its prompt, its toolCalls with the arguments,
    and its response" recorded an issue at line 231:31:
    Expectation failed: calls.first { $0.toolName == runCodeToolName }
      -> nil

    Test "the runCode call reaches the wire as a tool call update" recorded
    an issue at line 253:9:
    Expectation failed: creation.title == .value("runCode")
      creation.title -> unchanged
    and at line 254:9:
    String(describing: creation.rawInput).contains("return 1 + 1;")
      -> false, rawInput -> "unchanged"
    ```

    Both experiments are removed. The file holds neither of them now.

    **The green run.** `swift build` is clean. The root `swift test` gives
    488 tests in 51 suites, all passed, with the one known issue at
    `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`.
    The baseline was 484 tests in 50 suites; the four new proofs and their
    suite make the difference, and no test regressed.

    **The card's own question about the model's memory is already
    answered.** The comment of 2026-09-08 retracts it: `liveSession` is a
    `let`, held once, and the recorder only observes its transcript. A lost
    recording hides the snippet failures; it does not cause them. Card
    `^95jyv07` holds that question.
  timestamp: 2026-09-08T18:30:22.537977+00:00
- actor: claude-code
  id: 01m214qc20ec02g6f89qkn648k
  text: |-
    ### The byte-identity proof, and the third failure experiment

    The card asks for a test that the `instructions` entry is byte-identical
    across two turns while the tool surface stands unchanged. The recorder
    writes that entry ONE time per session — the first turn's diff records
    it, and later turns append after it — so two turns of one session leave
    one line, and one line cannot be compared with itself.

    The observable form of the same fact is two SESSIONS over one tool
    surface. Each session records its own `instructions` line, and each line
    carries the `parametersSchemaJSON` of every declared tool as a string.
    Equal strings are equal bytes. That is proof 5, and it reads exactly the
    bytes the false divergence came from.

    The recorded surface is the fixed four, and each schema is real:

    ```
    ["searchTools", "skills", "runCode", "wait"]
    {"additionalProperties":false,"properties":{"code":{...}},
     "required":["code"],"title":"RunCodeArguments","type":"object",
     "x-order":["code"]}
    ```

    The keys stand in sorted order, which is the correction `a3612d3` made.

    **Experiment C — an unstable order of the tool definitions.** I made the
    backend shuffle the tools before it declares them. Result:

    ```
    Expectation failed: firstDefinitions.map(\.name)
      == secondDefinitions.map(\.name)
      first  -> ["searchTools", "skills", "runCode", "wait"]
      second -> ["searchTools", "runCode", "wait", "skills"]

    Expectation failed: firstDefinitions.map(\.parametersSchemaJSON)
      == secondDefinitions.map(\.parametersSchemaJSON)
    ```

    The experiment is removed. The proof also asserts that no recorded
    schema is the empty-string sentinel, so an empty comparison cannot pass
    for the wrong reason.

    **The final run.** `swift build`: complete, no error. Root `swift test`:
    489 tests in 51 suites, all passed, one known issue at
    `HarnessSmokeTests.swift:239`. Baseline: 484 tests in 50 suites.
  timestamp: 2026-09-08T18:33:13.536299+00:00
- actor: claude-code
  id: 01m214r63chw4k49yxtfssgg3b
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift, Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift. swift build: complete. swift test: 489 tests in 51 suites passed, 1 known issue (HarnessSmokeTests.swift:239). Baseline: 484 tests in 50 suites.
    - next: review
  timestamp: 2026-09-08T18:33:40.204155+00:00
- actor: claude-code
  id: 01m2151wws3rjtd2penmndwyw3
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift:30 (scope: review sha HEAD~1..HEAD, commit ee7a1c7)
    - next: remove the empty @Suite attribute, then run the review again
  timestamp: 2026-09-08T18:38:58.457986+00:00
- actor: claude-code
  id: 01m21527vyatwsh1yy4mwtx5fs
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 2 files. The card became the agent-side verification after the user fixed the cause in the Router. Five proofs, with a red first run and three falsification experiments.
    - test: green — swift build complete; swift test 489 tests in 51 suites, one known issue (baseline 484 in 50)
    - commit: ee7a1c7 (13 files: the proofs, the scripted backend, the Router pin at cc51793, the eval model pin, and the board)
    - review: findings — Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift:30 (code-hygiene/idioms-swift, redundantSwiftTestingSuite)
  timestamp: 2026-09-08T18:39:09.694499+00:00
- actor: claude-code
  id: 01m2155720j9qd8angybwzk4fj
  text: |-
    ### The redundant @Suite attribute is removed

    The finding, word for word:

    `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift:30`
    `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove
    redundant @Suite attribute with no arguments.

    I looked at every `@Suite` attribute in the file. There is one, and it
    carries no arguments. The line is now:

    ```
    struct TranscriptFidelityTests {
    ```

    Swift Testing finds a type that holds `@Test` functions without the
    attribute, so the suite is still found. The test run shows
    `Suite TranscriptFidelityTests passed`, and the totals do not move:
    489 tests in 51 suites, the same as the baseline. The one known issue
    stays at `HarnessSmokeTests.swift:239`.

    No other file changed.
  timestamp: 2026-09-08T18:40:47.168943+00:00
- actor: claude-code
  id: 01m2155a28jn1nq6drwaxjxj93
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift. swift build: complete, no error. swift test: 489 tests in 51 suites passed, 1 known issue (HarnessSmokeTests.swift:239). The counts are the same as the baseline.
    - next: review
  timestamp: 2026-09-08T18:40:50.248189+00:00
- actor: claude-code
  id: 01m2159kpzchfpng3723tfh235
  text: |
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` (commit ea2ac1c). 7 validators ran. 0 findings. The round-1 finding at `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift:30` is closed: the bare `@Suite` attribute is removed, and the type is now a plain `struct TranscriptFidelityTests`.
    - next: none. The card moves to done.
  timestamp: 2026-09-08T18:43:11.199345+00:00
- actor: claude-code
  id: 01m2159ycy0hd8nhk5f9xfm4c6
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, the bare `@Suite` attribute removed. The suite is still found and its five proofs still pass.
    - test: green — swift test 489 tests in 51 suites, one known issue
    - commit: ea2ac1c
    - review: clean — 7 validators, 0 findings; the round-1 finding verified closed
    - the card is in done
  timestamp: 2026-09-08T18:43:22.142105+00:00
position_column: done
position_ordinal: be80
title: The instructions entry is rewritten every turn, and the differ discards the whole turn
---
### What

Every turn of the 2026-09-07 eval run was thrown away by the transcript
differ. Nothing of the turn was recorded, and nothing reached the wire.

The recorded marker, 29 times over 24 transcripts:

```
kind:  divergence
text:  backend transcript rewrote the recorded entry at index 0 in
       place: entry id <id> is unchanged but its content differs from
       what was recorded
```

Index 0 is the `instructions` entry. The entry keeps its id, and its
content changes under it.

**The consequence.** `recordTranscriptDelta` writes the marker, writes
NO diff, and resets the baseline. So over 24 transcripts there is no
`prompt` entry, no `toolCalls` entry and no `reasoning` entry at all.

`toolCalls` is the entry that carries `argumentsJSON` — the `runCode`
snippet source — so the source is lost. `emitSessionEvents` runs over
recorded diff partials, and a divergence makes none, so the wire loses
`SessionEvent.toolCall` as well.

### The cause, and where it was corrected

The cause is in `FoundationModelsRouter`, and the user corrected it
there. The pin is `cc51793`:

- `a3612d3` — `TranscriptEntryMapper` encodes each persisted schema with
  sorted keys. `GenerationSchema` encodes its objects from
  dictionaries, and a dictionary's iteration order changes between
  readings, so one unchanged tool definition encoded to different bytes
  and the baseline check reported a rewrite that never happened.
- `efcf8d7` — the transcript recorder appends only. A divergence is now
  a marker beside the recorded entries, and no turn is discarded.

- [x] Name what differs in the entry, byte for byte
- [x] Correct the cause, so the entry is stable across turns
- [x] Prove a turn is recorded whole: prompt, toolCalls, response

### Acceptance Criteria

- [x] A multi-turn session records no `divergence` entry.
- [x] A recorded turn holds its `prompt`, its `toolCalls` with
      `argumentsJSON`, and its `response` with an entry.
- [x] `SessionEvent.toolCall` reaches the wire for a `runCode` call.
- [x] The cause is named on this card, with the evidence that found it.

### Tests

`Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift`
holds five proofs over one scripted session.

- [x] A test drives two turns and asserts no `divergence` is recorded.
- [x] A test reads a recorded `toolCalls` entry back and finds the
      `runCode` source in `argumentsJSON`.
- [x] A test asserts the tool definitions of the `instructions` entry
      are byte-identical when the tool surface did not change. The
      recorder writes that entry one time per session, so the proof
      compares two sessions over one surface — see the comments.
- [x] A test asserts the recorded event count never falls between two
      reads of one session.
- [x] A test asserts `SessionEvent.toolCall` reaches the wire as the
      creating `tool_call_update` of the `runCode` call.

### Where the fix landed

In `FoundationModelsRouter`, under cards `^cybh869` and `^9hdy3hq`. This
card holds the agent-side verification, and it changed only this
repository:

- `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift` — the
  scripted backend synthesizes the transcript shape of a real model
  session.
- `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift` —
  the five proofs.

### Why this matters

This is not only a loss of evidence. The question whether the model
keeps its own history of a discarded turn is answered, and the answer is
no loss: `liveSession` is a `let`, held once, and the recorder only
observes its transcript. This defect HIDES the snippet failures; it does
not cause them. Card `^95jyv07` holds that question.

## Review Findings (2026-09-08 13:36)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Tests/FoundationModelsACPAgentTests/TranscriptFidelityTests.swift:30` `code-hygiene/idioms-swift` — redundantSwiftTestingSuite: Remove redundant @Suite attribute with no arguments.
