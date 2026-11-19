---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rgz9zpenaw6zcbgkwy4p8j
  text: |-
    ### review — clean
    - evidence: review sha e3a8da4~1..e3a8da4; findings 0, confirmed 0, refuted 1, attempted 7, failed 0. The engine reviewed 2 files.
    - next: none. The task is in done.
  timestamp: 2026-11-18T23:48:17.526561+00:00
depends_on:
- 01M7NQMF7QKY4Q0E6REQA7BTPC
position_column: done
position_ordinal: ffffff8780
title: 'ACPA-6: replay the session_message entries on load and resume'
---
Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, item 4. Decision D199 (f) in `TestudoApp/features/decisions.md`.

## Dependency

^qa7btpc (the `session_message` update for a delivered directory message).

## Current behavior

- The replay is in `SessionHistory.swift` (`:186`, `:250-253`), `SessionResume.swift` (`:636-685`) and `SessionResumeReplay.swift`. Find out if the replay keeps a `session_message` update and its `_meta`.

## Change

When a client loads or resumes a session, the transcript replay gives the same `session_message` entries as the live session: the same `messageId`, sender and recipient ids, content, and `_meta.sah.message`, in the same position before the chunks of the turn that the message started.

## Tests

- A load after a delivered user message replays the update with `sender.kind == "user"` and the source session id and title.
- A resume replays the update of a message from a session with `sender.kind == "session"`.
- The messages of the `agents` tool replay as today, with no double entry. #d199 #at-sessions #acpa-6