---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rmmpw213he7je9zbkfyzc3
  text: |-
    ### review — clean
    - evidence: review sha 91d6cb9~1..91d6cb9; 5 files reviewed; 0 findings, 0 confirmed, 2 refuted, 7 attempted, 0 failed, 0 skipped.
    - next: none. The task is in done.
  timestamp: 2026-11-19T00:52:24.578992+00:00
position_column: done
position_ordinal: ffffff8d80
title: A turn that a mail started writes session-history.json, so a resume after a crash keeps it
---
Found during ^v2y341x (2026-11-18).

## Current behavior

The agent writes the retained history (`session-history.json`, `Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift`) when a client prompt ends and at `session/close`. A turn that a mail started (a delivered directory message of the `sessions` tool, a user message from another session, or an `agents` tool mail) does not write the file. If the process stops hard after such a turn, a resume from disk loses that whole turn, with its `session_message` entry and the reply.

## Change

1. When a turn that a mail started ends, write the retained history, the same as at the end of a client prompt.
2. Use the same write path and the same order rules, so that a write does not race with a client prompt write.

## Tests

- After a turn that a directory message started, `session-history.json` holds the `session_message` entry and the reply, with no `session/close`.
- A resume from disk in a second agent, with no close of the first, replays that turn.
- An `agents` tool mail turn also writes the file. #acpa-6 #at-sessions