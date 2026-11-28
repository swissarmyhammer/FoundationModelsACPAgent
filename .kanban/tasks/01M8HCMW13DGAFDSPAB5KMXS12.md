---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8hcs03cp48h3mq6h839g0m8
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift. noSubcommandOfTheTreeIsAStub now runs `doctor --home <empty temp> --cwd <empty temp>` (makeResolvedDirectory), so the doctor reads no ~/.config/acp-agent and no dotfolder of the package. Build complete, no warnings. Not run yet: swift test waits for GO from the coordinator.
    - search: the outcomeError helper of CLIParsingTests is the one test path that calls a command's run() with the process environment. The other usage tests stop at the parse or at validate. Each other CLI test gives a fixture environment to perform(environment:) or report(environment:). ModelCacheDirectoryTests and OutOfProcessHomeTests read the process environment for paths only, and read no file of ~/.config.
    - note: the doctor still asks Hugging Face for the bundled profile, as before. A model that is not in the empty cache is an ok row, not a warning.
    - next: run the test at GO.
  timestamp: 2026-11-28T15:35:57.292762+00:00
- actor: claude-code
  id: 01m8hd479w8yw1d7eyzvg4g53k
  text: |-
    ### test — green
    - evidence: full `swift test --skip-build` after Build complete!: 2925 tests in 315 suites passed, 1 known issue (an intended withKnownIssue in HarnessSmokeTests). noSubcommandOfTheTreeIsAStub passes with ~/.config/acp-agent/config.yaml still holding the unknown `cluster:` section.
    - next: /review.
  timestamp: 2026-11-28T15:42:05.116171+00:00
position_column: done
position_ordinal: ffffffc280
title: CLIParsingTests must not read the real ~/.config
---
## Problem

`CLIParsingTests.noSubcommandOfTheTreeIsAStub` (`Tests/FoundationModelsACPAgentTests/CLIParsingTests.swift:227`) runs the real `doctor`. `doctor` reads the real `~/.config/acp-agent/config.yaml`. On 2026-11-28 the config of the user has a `cluster:` section, `doctor` warns "unknown section \"cluster\" is ignored", and the test fails. The result of the test must not depend on the machine.

## What to do

- Give the `doctor` run of the test an empty temporary `XDG_CONFIG_HOME`, or the test home of the package (see `Tests/FoundationModelsACPAgentTestSupport`).
- Look for other tests that run a subcommand on the real home, and isolate them the same way.
- Do not change the config file of the user.

## Acceptance criteria

- [ ] The test passes with any content in `~/.config/acp-agent/config.yaml`, also with an unknown section.
- [ ] No test reads the real `~/.config/acp-agent`. #bug