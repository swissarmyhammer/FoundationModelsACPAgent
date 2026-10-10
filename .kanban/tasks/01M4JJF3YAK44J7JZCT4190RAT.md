---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4kx58b8kx9sp215psfpmq4y
  text: |-
    ### Research (2026-10-10)

    - `ProcessCensus.agentServingACPPattern()` (IntegrationTests/.../Support/ProcessCensus.swift) gives `pgrep -f` the raw text `<locator path> acp`. `BuiltProductLocator.executableURL(named:)` gives the path of the products folder as SwiftPM states it, thus `/private/tmp/...` for a scratch path under `/private/tmp`. Foundation `Process` removes `/private`, thus the child command line is `/tmp/.../acp-agent acp`, and the pattern finds no process.
    - `pgrep` compiles its pattern with POSIX `regcomp(REG_EXTENDED)`, and `-f` matches anywhere in the full command line (no anchor). The raw path is not escaped, thus `.` in `.build` matches any character, and a path with `+`, `(` or `[` gives a wrong or invalid expression.
    - Design: a pure function `agentServingACPPattern(agentPath:)`. It removes a leading `/private` from the path and escapes each ERE metacharacter. The pattern has no anchor, thus `<path without /private> acp` matches the command line with `/private` and the command line without it. The selection by parent (`-P`) and the ` acp` subcommand stay, thus a parent `acp-agent run ...` still does not match, and a child that outlives the run is still an orphan the census finds.
    - I do not resolve symlinks: the child gets the path as the locator gives it (only `/private` is removed by `Process`). A full symlink resolution could give a path that is not in the command line.
    - The unit test matches with Darwin `regcomp`/`regexec` and `REG_EXTENDED`, the same engine `pgrep` uses.
  timestamp: 2026-10-10T21:57:57.736251+00:00
- actor: claude-code
  id: 01m4kxrhzy6qyc3qdxma95n5y6
  text: |-
    ### implement — changed
    - evidence: 2 files — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/ProcessCensus.swift (new `agentServingACPPattern(agentPath:)`: removes a leading `/private`, escapes ERE operators), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/ProcessCensusTests.swift (new, 3 tests, 4 cases, matched with `regcomp`/`regexec` and `REG_EXTENDED`, as `pgrep`).
    - TDD: RED (`--filter ProcessCensusTests`, IntegrationTests/.build/alt): 2 issues — the `/tmp/x/acp-agent acp` case (`pattern: /private/tmp/x/acp-agent acp`) and `aDotInThePathMatchesOnlyADot`. The seam for RED kept the old behavior (`"\(agentPath) acp"`). GREEN: 3 tests in 1 suite passed.
    - OutOfProcessTests (`--filter OutOfProcessTests --force-resolved-versions`): scratch path `<session scratchpad>/it-build` under `/private/tmp`: 2 tests passed. Scratch path `IntegrationTests/.build/alt`: 2 tests passed.
    - full suites, each with `SKILLS_MARKETPLACE_CACHE` set to a new empty scratch folder: `swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel` — 33 tests in 12 suites passed. `swift test --scratch-path .build/alt --force-resolved-versions` — 883 tests in 96 suites passed, 1 known issue (the intended `withKnownIssue` in HarnessSmokeTests). The only warning is the mlx-swift_Cmlx.bundle build line (dependency). No warning in a file of this package. No skip.
    - note: the `dump validators` rules file is 754K characters. I read the rule bodies that apply to Swift (code-hygiene prompt rules and the Swift tool rules, code-security, completeness, duplication, reuse, swift, test-integrity), not the script details of the other languages.
    - All 4 items of the card are `- [x]`. Not committed. The task stays in `doing`.
    - next: /review.
  timestamp: 2026-10-10T22:08:30.206684+00:00
- actor: claude-code
  id: 01m4ky1vzxr6c34t3s0hvsc4y2
  text: |-
    ### test — green
    - evidence: `swift test --scratch-path .build/alt --force-resolved-versions` — 883 tests in 96 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests), 0 failed, 0 skipped. `swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions` — 33 tests in 12 suites passed, 0 failed, 0 skipped. Both used an empty SKILLS_MARKETPLACE_CACHE folder. Only warning in both: the mlx-swift dependency warning (missing creator for mutated node, mlx-swift_Cmlx.bundle). No package warnings.
    - next: none. No files changed.
  timestamp: 2026-10-10T22:13:35.357835+00:00
position_column: doing
position_ordinal: '80'
title: 'OutOfProcessTests: the pgrep pattern finds no child process when the build folder is under /private/tmp'
---
## Problem

Found on 2026-10-10 in task ^c4a6mwy. `OutOfProcessTests.noProcessOfTheChildsGroupOutlivesTheRun` fails each time when the build folder is under `/private/tmp`, and passes when the build folder is under `$HOME`.

Cause: Foundation `Process` removes the `/private` prefix, so the child process runs as `/tmp/.../acp-agent acp`. The `pgrep` pattern in `ProcessCensus` keeps `/private/tmp/...`, so it matches no process. Thus, the test cannot see a child process that outlives the run, and it fails for a reason that is not the behavior under test.

## Change

- [x] Make the `ProcessCensus` pattern match both path forms. Done by `ProcessCensus.agentServingACPPattern(agentPath:)`: it removes a leading `/private` from the path and escapes each operator character of an extended regular expression. `pgrep -f` matches without an anchor, thus the pattern finds `/tmp/...` and `/private/tmp/...`. Symlinks are not resolved: the child gets the path of the locator, with only `/private` removed by `Process`. Test: `ProcessCensusTests.aPrivateTemporaryPathFindsTheChildInEachPathForm(commandLine:)` (2 cases).
- [x] Do not weaken the check: a child process that outlives the run must still make the test fail. The selection by parent (`-P 1` for orphans, `-P <run>` for children) and the ` acp` subcommand are unchanged. The path now matches only as literal text (before, `.` matched any character). Tests: `ProcessCensusTests.theParentRunOfTheSameBinaryDoesNotMatch`, `ProcessCensusTests.aDotInThePathMatchesOnlyADot`, and the success row of `OutOfProcessTests.noProcessOfTheChildsGroupOutlivesTheRun`, which requires that the census sees exactly 1 live child under `/private/tmp`.

## Tests

- [x] Run the suite with a build folder under `/private/tmp` and under `$HOME`. Both pass. `swift test --package-path IntegrationTests --filter OutOfProcessTests --force-resolved-versions`: with `--scratch-path <session scratchpad>/it-build` (under `/private/tmp`) 2 tests passed; with `--scratch-path IntegrationTests/.build/alt` (under `$HOME`) 2 tests passed.
- [x] A test of `ProcessCensus` itself: a pattern made from `/private/tmp/x/acp-agent` matches a process whose command line is `/tmp/x/acp-agent acp`. Test: `ProcessCensusTests.aPrivateTemporaryPathFindsTheChildInEachPathForm(commandLine:)`, case `/tmp/x/acp-agent acp`. Seen failing first (RED: `pattern: /private/tmp/x/acp-agent acp`).

#tests