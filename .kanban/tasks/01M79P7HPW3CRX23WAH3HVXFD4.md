---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'SubagentMessageWireTests: the final view test fails under high machine load'
---
## What
During a full `swift test` run on 2026-11-12 (load average approximately 17, with a concurrent review run), the test "the incoming view of the final message comes before the last update of the agents call" (`theFinalViewComesBeforeTheFinalStatus`, Tests/FoundationModelsACPAgentTests/SubagentMessageWireTests.swift) failed with `view → nil`: the root stream held no `session_message` view of the final text of the child. Each test of the suite took approximately 40 seconds in that run. The same suite passed alone in 6.7 seconds, and the same test passed in the full run before it, with no related code change between the runs (found during ^f9wmtse).

1. Find why the root stream can end with no incoming view of the final message of the child under load (a wait that ends at a status and not at the view, or a view that a timing gap drops).
2. Correct the cause in the code or the wait of the test. Do not add a retry and do not increase a timeout to hide the cause.

## Acceptance Criteria
- [ ] The cause is named on this card.
- [ ] The test passes under a loaded full run.

## Tests
- [ ] A test that makes the timing gap occur deterministically, and that fails before the fix.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd`.