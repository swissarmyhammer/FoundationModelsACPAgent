---
depends_on:
- 01M84SECTWZ5B0VPAYAH051P1B
position_column: done
position_ordinal: '80'
title: 'D212: the real-disk test of ExternalSessionIndex in IntegrationTests (5,000 generated files)'
---
Section 7 of the D212 design asks for an opt-in test on the real disk: 5,000 generated Claude Code files; the first row in less than 1 s, and the peak memory of the process increases by less than 100 MB.

Step 2 (^h051p1b) did not add it. This repo has no opt-in test that an environment variable gates, and the test-partitioning validator forbids that gate. The structural place is the nested IntegrationTests package (swift test --package-path IntegrationTests).

Work:
- ExternalSessionIndex is internal. The IntegrationTests package reaches the library as a product, so it needs a public way in: for example RoutedACPAgent.setImportRoots plus a public query of the index after step 3, or a public test-support entry in FoundationModelsACPAgentTestSupport.
- Generate 5,000 files in a temporary folder under the scratch path of the test (remove them at the end; the disk filled on 2026-10-17 from leaked test folders).
- Measure the time of the first row of a folder query with a clock, and the peak memory with task_info (phys_footprint) before and after the build.
- No time-limit trait, no sleep, no retry.
## Result
- The public way in: `RoutedACPAgent.externalSessionHost`.
- The test: IntegrationTests `ExternalSessionRealDiskTests` (5,000 files in 50 project folders, 50 files of 1 MB, in a temporary folder that the test removes).
- One run: the first row of a folder in 0.11 s, the full build in 0.47 s, and the peak memory increase 28 MB.
- The root unit suite: 2850 tests pass, with 1 known issue.
