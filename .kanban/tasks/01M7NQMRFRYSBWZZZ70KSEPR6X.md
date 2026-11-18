---
assignees:
- claude-code
depends_on:
- 01M7NQMF7QKY4Q0E6REQA7BTPC
position_column: todo
position_ordinal: '8280'
title: 'ACPA-6: show a directory message that the session reads with inbox, once'
---
Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, item 3. Decision D199 (f) in `TestudoApp/features/decisions.md`.

## Dependency

^qa7btpc (the `session_message` update for a delivered directory message). The Router puts a message for a recorded target into its inbox file (`router-brief-at-sessions.md`).

## Change

A directory message that the session reads with `inbox` (no turn starts) still gives one `session_message` update to the client of the target, with the same `_meta.sah.message` sender as in ^qa7btpc. Read the message one time only: a second `inbox` read, or a later turn, does not send it again.

## Tests

- A message in the inbox, read with `inbox`: one `session_message` update with the correct sender kind.
- A second read does not send a second update. #d199 #at-sessions #acpa-6