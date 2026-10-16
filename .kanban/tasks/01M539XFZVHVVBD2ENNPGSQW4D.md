---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53azb1gbj2ycyne8t8az5x3
  text: 'Done in d9d5ae1. (a) WireAnswer reads _meta.reason; a decline or cancel goes to Router with it. (b) CancelReason: noConnection, requestFailed, answerNotValid. (c) The drain gives Router cancel with feedEndedCancelReason. Gap for a follow-up on ACPClient: SessionModel.declineElicitation/cancelElicitation take no reason, so no client of this family sends _meta.reason yet.'
  timestamp: 2026-10-16T21:48:00.432306+00:00
position_column: done
position_ordinal: ffe780
title: 'R4: reasons go back to Router'
---
Defect (group B, rule R4).
(a) WireAnswer reads only action and content, so the client's `_meta.reason` of a decline or cancel is lost. Read it and give it to Router in ElicitationResponse.reason.
(b) A missing connection and a failed create give Router .cancel with no reason. Give a reason.
(c) The drain gives Router .cancel with no reason, but the wire cancel carries feedEndedCancelReason. Give Router the same reason.

Test first: each test must fail on the old code. #elicitation