---
position_column: todo
position_ordinal: '80'
title: 'Plan update: compose Router directly (harness collapse) + rename the conformance'
---
The 2026-07-23 collapse folds FoundationModelsAgentHarness into Router (Router board task m2mvmdn). Update plan.md: layering diagram and dependency list drop the harness; the composition pipeline becomes router.makeSession(workingDirectory:tools:instructions:budget:compactionPrompt:) — Router sessions are self-folding, token-metered, event-streaming, recorded. Rename HarnessACPAgent (no Harness type exists): decide RoutedACPAgent vs ACPAgent and sweep the plan. Re-point section references at Router's plan/compaction plan where the harness plan is cited. Do not touch the harness repo itself (active session rooted there).