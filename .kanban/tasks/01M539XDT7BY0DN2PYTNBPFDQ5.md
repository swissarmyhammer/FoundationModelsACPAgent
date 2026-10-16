---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53az9694tnqrm1nmpfcc4qd
  text: 'Done in e819566. The drain keeps the early ends and sets feedEnded. A late relay of an ended question sends no create and does not answer Router again (Router already gave the response of the end). Any other late relay sends no create and gives Router cancel with "the session ended". ElicitationRelayOrderTests: 2 tests, both fail on the old code.'
  timestamp: 2026-10-16T21:47:58.537515+00:00
position_column: done
position_ordinal: ffe680
title: 'R2: no elicitation/create for a question that has an end'
---
Defect (group A, rule R2). drainOpenRoundTrips in ElicitationRelay sets `earlyEnds = [:]`. SessionProjector starts each relay() in its own task with no fixed order. Scenario: Router sends elicitationRequested, then session/close sends elicitationEnded and the feed ends. end() keeps the end in earlyEnds, the drain clears that list, then the late relay task sends elicitation/create on a connection that is still open. Nothing cancels it, so the client shows a question that never ends.

Fix: after the drain, or after an end for that id, a late relay() for that id sends nothing and gives Router cancel with a reason.

Test first: the test must fail on the old code. #elicitation