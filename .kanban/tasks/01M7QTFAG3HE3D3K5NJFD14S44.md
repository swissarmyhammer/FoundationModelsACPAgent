---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rgnst1j32jxrs1jfthqbkw
  text: |-
    ### review — findings
    - evidence: review sha 6898956~1..6898956; findings 1, confirmed 1, refuted 0, attempted 7, failed 0. Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift:192 (reuse/reuse). No validator matched cli-plan.md, and the engine did not review it.
    - next: correct the finding in the section "Review Findings (2026-11-18 17:41)". The task stays in review.
  timestamp: 2026-11-18T23:43:06.049551+00:00
- actor: claude-code
  id: 01m7rhkag2jw4y7c41a31m2cng
  text: 'Review fix (2026-11-18): `ProfileDoctor.bytesPerGigabyte` is now an internal `Int64` (the format converts it to `Double`). `DocumentationSyncTests` imports `FoundationModelsACPAgent` with `@testable` and uses `ProfileDoctor.bytesPerGigabyte`; the copy in the test is deleted. DocumentationSyncTests and ProfileDoctorTests: 29 passed.'
  timestamp: 2026-11-18T23:59:13.410294+00:00
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: doing
position_ordinal: '8380'
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

## Review Findings (2026-11-18 17:41)

> Scope: `review sha 6898956~1..6898956` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `cli-plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift:192` `reuse/reuse` — The new constant bytesPerGigabyte is a second copy of the byte count of one gigabyte. ProfileDoctor already holds that value at its line 49, as a private Double. The copy is Int64, so the test cannot reuse the production constant. Two copies of one unit must be kept in step by hand. Widen the production constant to internal, or give it an internal accessor, and let the test use it through @testable import. Then delete the copy at line 192. If the test must keep an Int64 form, derive it from the one production value instead of writing the number again.