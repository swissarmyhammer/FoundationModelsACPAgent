---
assignees:
- claude-code
position_column: todo
position_ordinal: 9f80
title: Fill tool_call_update locations from the structured per-call record
---
## What
The tier-2 projection proof (task ^qg1rfct) could not assert `locations`. No code path fills `tool_call_update.locations` today. The events the projection receives — `toolCall`, `toolStatus`, `runSettled` — carry no path data. Plan.md §11.5 and §11.6 say the `locations`, `rawInput`, `rawOutput` and `content` fields need the structured per-call record from the capability, not its model-facing rendered string.

## Why
Plan.md §20.1 proof 3 asks for filled `locations` on a real tool call. The wire never carries them, so a client cannot show the touched files.

## How
- Find or request the structured per-call record from the files capability and the mcp capability.
- Map the record's paths to `ToolCallLocation` values in `EventProjection`.
- Replace `locations` as a whole array (plan.md §11.6).
- Extend `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` proof 3 to assert the filled `locations`.

## Acceptance Criteria
- [ ] A real `tools.files.write` through the wire shows the written path in `locations`
- [ ] The tier-2 proof 3 asserts `locations` and stays green