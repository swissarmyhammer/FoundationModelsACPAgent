---
assignees:
- claude-code
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: todo
position_ordinal: 8d80
title: 'ACPA-23 (D203): the doctor memory floor is 16 GB, not 32 GB'
---
Found during ^56r9vp9 (2026-11-18). Decision D203 in `TestudoApp/features/decisions.md`: the agent needs a Mac with 16 GB of memory or more.

## Dependency

^56r9vp9 (the three bundled profiles; the README now says 16 GB).

## Current behavior

The doctor check uses a 32 GB memory floor (`Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift`). Thus `acp-agent doctor` reports an error on a 16 GB Mac, which D203 supports.

## Change

1. The memory floor of the doctor is 16 GB.
2. The doctor text names the profile that fits the memory, if it is easy to get from the fit (do not add a fit read only for this).
3. Find each other place that names 32 GB as the minimum (README, tool texts, doctor texts, tests) and change it to 16 GB.

## Tests

- A memory of 16 GB gives no floor error.
- A memory under 16 GB gives the floor error, and the text names 16 GB.
- The test that checks the README floor and the doctor floor agree. #d203 #profiles #acpa-23