---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4mn02bq2ejgx44e83xh1fgh
  text: |-
    Research done.
    - `rg ACP_TIER` over the repo: only cli-plan.md §9 (5 rows). No other doc or source names ACP_TIER3 or ACP_TIER4.
    - The "Unit" and "Integration" tier rows of §9 all run in the root unit target (Tests/FoundationModelsACPAgentTests): CLIParsingTests, PromptSourceTests, ExitCodeTests, DoctorCommandTests, ConfigInitTests, ConfigShowTests, Doctor/*DoctorTests, RunCommandTests, AcpCommandTests, AnswerWriterTests, EventLineWriterTests, ProgressReporterTests.
    - Tier-3 rows: ClientServerTests (acp-print), ClientInteropTests (library in process), OutOfProcessTests (same answer, and the interrupt row with exit 4 and the process census). All in the IntegrationTests package; each header says the package boundary is the selection.
    - Tier 4: no suite exists. No test runs `doctor` on a clean machine. ProfileDoctorTests.anAbsentReferenceStatesWhatTheNextRunDownloads proves the report against a fixture in the root unit target.
  timestamp: 2026-10-11T04:54:33.591504+00:00
- actor: claude-code
  id: 01m4mn68gjw1721rkjey7xx3mx
  text: |-
    ### implement — changed
    - evidence: 1 file — cli-plan.md (§9 only). The `Gate` column is now `Target`. Each cell names the target and the suite: "Root unit target: <suite>" for the 10 Unit rows and the 6 Integration rows, and "`IntegrationTests` package: <suite>" for the 4 tier-3 rows (ClientServerTests, ClientInteropTests, OutOfProcessTests x2). The tier-4 row says that no suite exists, and names ProfileDoctorTests as the fixture-level check in the root unit target. A new paragraph above the table names the two targets, says that the "Integration" rows run in the root unit target, and says that no environment variable selects a test. No row named a suite that does not exist before this change: the old rows named no suite.
    - proof: `rg -n "ACP_TIER" cli-plan.md` gives no match (exit 1). `rg -l "ACP_TIER3|ACP_TIER4" .` gives no match. With `--hidden`, only `.kanban/tasks/*` records match (task history, not doc or source); they are not changed.
    - next: /review
  timestamp: 2026-10-11T04:57:56.498444+00:00
- actor: claude-code
  id: 01m4mnkf16screejnvkvrppm24
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (452f8e8): 0 findings, 0 confirmed, 0 refuted. The engine reviewed 0 files. No validator matches `cli-plan.md`, and `.reviewignore` excludes the 2 `.kanban/` files.
    - hand check, suites: each suite in the `Target` column exists in the stated target. Root unit target (`Tests/FoundationModelsACPAgentTests`): CLIParsingTests, PromptSourceTests, ExitCodeTests, DoctorCommandTests, ConfigInitTests, ConfigShowTests, RunCommandTests, AcpCommandTests, AnswerWriterTests, EventLineWriterTests, ProgressReporterTests, and `Doctor/` (ConfigurationDoctorTests, DoctorRegistryTests, ProfileDoctorTests, RuntimeDoctorTests, ToolsDoctorTests, TranscriptsDoctorTests). `IntegrationTests` package: ClientServerTests, ClientInteropTests, OutOfProcessTests.
    - hand check, rows: each named suite has a test for its row. Examples: `cwdWithResumeIsAUsageError`, `runDoctorIsThePromptDoctorAndNotTheCheck`, `aSecondInitWithoutForceRefusesAndChangesNoFile`, `cwdSelectsTheProjectLayer`, `eachSessionResolvesItsOwnProjectLayer`, `aPipedRunWithNeitherFlagWritesZeroBytesToStandardError`, and the interrupt case of OutOfProcessTests that expects exit 4. No test runs `doctor` on a clean machine, so the tier-4 row is correct.
    - hand check, text: the new text is in ASD-STE100.
    - acceptance: `rg -n "ACP_TIER" cli-plan.md` gives no match (exit 1). Both task items are checked.
    - next: none. The task is in done.
  timestamp: 2026-10-11T05:05:09.158534+00:00
position_column: done
position_ordinal: ffc080
title: 'cli-plan.md §9: the Gate column names ACP_TIER3=1 and ACP_TIER4=1, but no suite has an environment gate'
---
## Problem

The `Gate` column of the test table in `cli-plan.md` §9 gives `ACP_TIER3=1` for each tier-3 row and `ACP_TIER4=1` for the tier-4 row. The suites carry no environment gate. The package boundary is the selection: the root `swift test` does not see the `IntegrationTests` package, and `swift test --package-path IntegrationTests` runs it (see the header comments of `ClientInteropTests`, `TierThreeFixture` and the `IntegrationTests/Package.swift` doc). The org test contract forbids an environment variable that selects a test.

Found while doing ^dn561z8. That task changed one tier-3 row and kept the column as it is, because the column is outside its scope.

## Change

- [x] Replace the `Gate` column of `cli-plan.md` §9 with the target that selects each row: `none` (root unit target) or the `IntegrationTests` package. Check whether a tier-4 suite exists; if it does not, say so in the row.

## Tests

- [x] `rg -n "ACP_TIER" cli-plan.md` gives no match. This is a document change, so no code test applies.

#docs