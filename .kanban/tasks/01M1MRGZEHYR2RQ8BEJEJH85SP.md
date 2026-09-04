---
assignees:
- claude-code
depends_on:
- 01M1MP01P7SV7C2S0S8QZ0A60T
- 01M1MNXY19R8HPEMNGF2WXB0G6
position_column: todo
position_ordinal: '9880'
title: '--verbose and --quiet: the session event lines on stderr'
---
### What

cli-plan.md §5.7, the half that is not the download bar. Split out of
the progress card because it is a separate concern: a projection of
session events into one line each, with its own tests.

In `Sources/acp-agent/EventLineWriter.swift`:

- `--verbose` writes the session events to stderr, one line each: the
  tool calls (name and status), the plan updates, and the stop reason.
  **In a pipe too** — this is a person asking to see the events, not
  decoration.
- `--quiet` writes nothing but errors, in a terminal too. It also turns
  off the download bar of the progress card.
- Neither option touches stdout. §5.6 stays byte-exact.
- Without either option, a successful run writes nothing to stderr.

The projection reads the same `SessionUpdate` stream the CLI already
consumes for the answer text. One line per event, stable and parseable,
with no ANSI escape — a piped `--verbose` run is something a person
greps.

- [ ] `EventLineWriter`, with an injected destination
- [ ] `--verbose`: one line per tool call, plan update and stop reason
- [ ] `--quiet`: errors only, and the bar off
- [ ] Neither option by default: stderr stays silent

### Acceptance Criteria

- [ ] With `--verbose` and a pipe destination, a scripted turn that
      makes two tool calls writes exactly one line per event.
- [ ] The `--verbose` output holds no `ESC[` sequence.
- [ ] With `--quiet`, a run with a terminal destination writes nothing
      but an error.
- [ ] With neither option and a pipe, a successful run writes zero bytes
      to stderr.
- [ ] stdout is byte-identical in all four cases.

### Tests

- [ ] `EventLineWriterTests`: a scripted event stream with two tool
      calls, one plan update and a stop reason gives four lines, in
      order.
- [ ] The piped `--verbose` output holds no `ESC[`.
- [ ] `--quiet` with a terminal destination writes only the error.
- [ ] The default case writes zero bytes.
- [ ] A test asserts stdout is byte-identical across all four flag
      combinations for one scripted turn.
- [ ] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.