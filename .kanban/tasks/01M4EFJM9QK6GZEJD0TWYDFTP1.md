---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4erx1gegdxqdyp55r5v9f95
  text: 'Research: `BuiltinConfigurationFile` is internal to the library, thus the `acp-agent` target cannot call `BuiltinConfigurationFile.url()`. Plan: add a public static accessor `ConfigurationLoader.builtinConfigurationFileURL()` that forwards to `BuiltinConfigurationFile.url()`. In `Config.Path`, remove `Location.code` and the "(in code, no file)" text; each row then holds a path and an exists mark. The builtin row shows the file path, without the directory suffix "/". Unit tests: `ConfigPathTests` (the existing builtin assertions say "no mark", which the change makes false, thus they change). Integration test: `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` checks only the row count and the "builtin" prefix.'
  timestamp: 2026-10-08T22:07:22.126705+00:00
- actor: claude-code
  id: 01m4es5sf3403kezmswjmn83h2
  text: |-
    Implementation done.
    - Library: new public `ConfigurationLoader.builtinConfigurationFileURL()`. It forwards to the internal `BuiltinConfigurationFile.url()`. The CLI target cannot see the internal type, thus the accessor is necessary.
    - CLI `Config.Path`: removed `Location` (`.code` / `.directory`) and `codeLocation` "(in code, no file)". `Row` now holds `path` and `exists`. The builtin row is the bundle path of `builtin.config.yaml` with the `exists` / `missing` mark (`FileManager.fileExists`). A directory row keeps the "/" suffix. All rows now share one path column and one mark column.
    - Contract note: when the resource bundle has no builtin file, `config path` now throws `BuiltinConfigurationFileError.missing`. Before, it printed a row. Each configuration load (`config show`, each session) fails the same way in that case, thus the doc comment of `report(environment:)` states it.
    - TDD: RED was `ConfigPathTests.theBuiltinRowNamesTheBuiltinFileThatExists` (it got "builtin  (in code, no file)"), then GREEN. The old builtin assertions in `theThreeLayersCarryTheRightMarks` said "no mark", which the card makes false, thus I removed them. `BuiltinConfigurationFileTests.theLoaderGivesTheLocationOfTheFileThatLoads` covers the public forwarder. I wrote it after the one-line forwarder, not before.
    - Integration: `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` now also checks that the builtin row of the built binary names `/builtin.config.yaml` and ends with `exists`.
    - No doc file holds "(in code, no file)". cli-plan.md and README.md text stays true.
  timestamp: 2026-10-08T22:12:08.803192+00:00
- actor: claude-code
  id: 01m4es5w48zq3r8m3wmve914bm
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift, Sources/acp-agent/ConfigCommand.swift, Tests/FoundationModelsACPAgentTests/ConfigPathTests.swift, Tests/FoundationModelsACPAgentTests/BuiltinConfigurationFileTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/CLIProcessTests.swift. `swift test`: 818 tests in 88 suites passed (1 intentional known issue in HarnessSmokeTests). `swift test --package-path IntegrationTests --filter CLIProcessTests`: 7/7 passed. The one build warning ("missing creator for mutated node" for the mlx-swift_Cmlx bundle) comes from the build system for a dependency. It was there before this change.
    - next: /review
  timestamp: 2026-10-08T22:12:11.528518+00:00
- actor: claude-code
  id: 01m4ese69h4tn815tgag7s4vtr
  text: |-
    ### test — green
    - evidence: swift test (root) — 818 tests in 88 suites passed, 0 failed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests); swift test --package-path IntegrationTests --no-parallel — 30 tests in 11 suites passed, 0 failed. Zero skipped. The only warning is the mlx-swift_Cmlx.bundle build-system line from a dependency. No file was changed.
    - next: review
  timestamp: 2026-10-08T22:16:44.081598+00:00
- actor: claude-code
  id: 01m4esep8zz7xrbcq97jrenz10
  text: |-
    ### commit — changed
    - evidence: 94237a5 fix(cli): show the builtin configuration file in the config path builtin row (^wydftp1)
    - next: none
  timestamp: 2026-10-08T22:17:00.447766+00:00
- actor: claude-code
  id: 01m4esrn2729k0tqb7877drw7s
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (94237a5). 0 findings, 0 confirmed, 0 refuted. 5 files reviewed. 2 .kanban files not reviewed (.reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-10-08T22:22:26.887729+00:00
- actor: claude-code
  id: 01m4ess0geehebdrsyr7p54ye5
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files
    - test: green — swift test 818 passed (1 known issue, HarnessSmokeTests); IntegrationTests --no-parallel 30 passed
    - commit: 94237a5
    - review: clean — 0 findings
  timestamp: 2026-10-08T22:22:38.606307+00:00
depends_on:
- 01M4E2BEVVM2SHK85XG9DGE8CC
position_column: done
position_ordinal: ffad80
title: 'config path: show the builtin configuration file in the builtin row'
---
## Problem

Task ^9dge8cc ships the builtin configuration as the file `builtin.config.yaml` in the resource bundle of the library. `config path` (`Sources/acp-agent/ConfigCommand.swift`, `Config.Path`) still prints the builtin row as "(in code, no file)", and the `Location.code` doc comment says "the builtin defaults have no file". That text is not true now.

## Decision

The builtin row of `config path` shows the path of the builtin file in the resource bundle (`BuiltinConfigurationFile.url()`), with the "exists" mark, in place of "(in code, no file)".

## Tests

- `config path` prints the builtin row with the path of `builtin.config.yaml`, and the path exists.
- `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` stays green with the built binary.

#config