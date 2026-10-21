---
assignees:
- claude-code
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
position_column: doing
position_ordinal: '80'
title: 'ACPA-5c: the owner of a session is a connection id; requests for the user go to the owner only'
---
Spec: ACPA-5 (D120 c, D11), TestudoApp foundationmodels-acpagent.md.

## Change
- `session/new` sets the owner to the connection id of the call. It also records the connection that started the session, which ACPA-13 needs for the visibility rule of an `external` viewer.
- A `session/load` or `session/resume` from a `userDevice` connection takes the session. The old owner loses it, and gets no more requests for input.
- An `external` connection cannot take a session that has an owner. Give a coded error.
- The requests that need the user (permission, elicitation) go to the owner connection only. `session/update` goes to the owner as well.
- The owner record and the started-by record are in memory only. After a restart, no session has an owner.

## Done when
- A failing test first (TDD), with two connections A (userDevice) and B (external):
  - A makes a session. Its permission request goes to A only.
  - B cannot take it.
  - A second userDevice connection C takes it with session/resume. Then the requests go to C, and A gets none.
- The full `swift test` passes. #acpa-5