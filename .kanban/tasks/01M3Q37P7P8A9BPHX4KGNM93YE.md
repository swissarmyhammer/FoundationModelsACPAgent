---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: Prove or rule out a session/close hang when a mail-started answer waits for a place in the model queue
---
## Why

The work on ^m0k2vn6 saw one `session/close` that did not return in 60 s (see the first comment of ^6kcts5v). The tests of ^6kcts5v prove that a close ends a CALLER prompt that waits for a queue place. They do not examine an answer that the MAIL of a settled background run starts. That shape is still open.

## Reproduction of the earlier observation (from ^6kcts5v)

1. Two sessions on one queued scripted model (one pool entry). Each session has its own working directory.
2. The script is one `runCode` with `tools.shell.execute({ command: "cat release.fifo && rm release.fifo" })`.
3. The cwd of A holds a named pipe `release.fifo`. The cwd of B holds a plain file with that name.
4. B's shell run settles at once. Its mail starts mail-only answers. Each answer plays the script again, so B loops until `mailOnlyAnswerLimit` (100).
5. The test writes A's pipe. A's shell run settles, and A has mail that waits for the queue.
6. `session/close` for A does not return in 60 s. A's mail answer never gets a pass (the log shows no second `runCode` for A).

## What

1. Write a test with a time limit that makes one session hold the model (`.holdUntilReleased`) while a mail-started answer of the other session waits for a queue place. Then close the waiting session.
2. If the close does not answer, find if the cause is Router `close()`/`drain()`. If it is, record the defect with exact steps for the Router session. Do not work around it in this repository.

## Acceptance Criteria

- [ ] A test proves that `session/close` answers while a mail-started answer of that session waits for a queue place, or the card records a Router defect with reproduction steps.

#generation-queue