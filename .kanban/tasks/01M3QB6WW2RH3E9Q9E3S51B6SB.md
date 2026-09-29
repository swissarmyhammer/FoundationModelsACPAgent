---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: Remove the obsolete `wait` tool from the test support doc comments and the ScriptedModel collecting play
---
## Why

Multitool mounts no `wait` tool (plan.md §8.0, §11.1). A settled background run comes back to the session as mail. The test support still names a `wait` call, so a reader learns a wrong surface.

## What

Rewrite these places for the mail model. Write in ASD-STE100 Simplified Technical English.
- `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift`: the doc comments that name "the `wait` play" and "a `wait` call that names the run", and the doc comment of `completionTokenField` ("the field a `wait` call names the run to collect under"). Find out if the collecting play is still used. If no test uses it, remove it; if a test uses it, rewrite its doc comment so that it does not name a `wait` tool.
- `Tests/FoundationModelsACPAgentTests/Support/RecordedTranscriptFile.swift`: the doc comment of `completionTokenKey` ("the background run a `wait` collects").

## Acceptance Criteria

- [ ] `rg -n "\`wait\`" Tests IntegrationTests` shows no line that tells of a `wait` tool as if it exists.
- [ ] `swift test` passes with zero compiler warnings.

Found by ^f4tye31. #generation-queue