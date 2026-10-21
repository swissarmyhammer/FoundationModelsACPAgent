---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5g5y2f41q5xs8x3nntvfwvm
  text: |-
    ### implement — changed
    - evidence: d8fe637. RED first: SessionOwnerTests.theRequestsOfASessionGoToItsOwnerAndOnlyAUserDeviceTakesIt failed at "expected the refusal of an external take" (the external resume took the session). GREEN after the change. Full `swift test`: 1177 tests in 129 suites passed, 1 known issue.
    - The test: A (userDevice, loopback eliciting MCP server) makes a session; its elicitation goes to A only (B and C recorders empty). B (external, bind trust from the harness) gets invalid request with data.code SESSION_HAS_OWNER on session/resume. C (userDevice) resumes it: owner == C, starter == A; C's prompt's elicitation goes to C (1 create), A keeps 1 create and gets no new idle.
    - Notes: the agent sends no session/request_permission at all (the Seatbelt sandbox is the only gate), so "the requests that need the user" are the elicitations; they go to the owner via ElicitationRelay's outbound path. A non-owner may still prompt a session (the spec does not forbid it); the echo and the updates go to the owner.
    - Trust seam: bind(connection:trust:) — the host gives the trust (stdio/in-process default userDevice). ^bxst844 stays blocked on ACP-1 for the bearer token.
    - Found while testing: AgentClientHarness.close waited for every bound connection (waitForConnectionTeardown), so closing one of several harnesses on one agent hung; added waitForTeardown(of:) and the harness uses it.
    - next: ^s415rd3
  timestamp: 2026-10-21T21:30:03.620509+00:00
depends_on:
- 01M5G0JS7YFSWXJXXHEZNEPBKJ
position_column: done
position_ordinal: ffff8480
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