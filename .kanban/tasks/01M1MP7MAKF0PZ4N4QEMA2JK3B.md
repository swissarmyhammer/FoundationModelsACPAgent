---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21y419mcemcq9qwc2dcnkhd
  text: |-
    Research done. What the code says today:

    - `ProfileConfiguration` statics (Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift): standard `mlx-community/Qwen3.8-27B-mxfp4`, flash `mlx-community/Qwen3-4B-4bit`, embedding `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. The standard slot is the mxfp4 build, NOT the 4bit build (card ^s0bw5cv).
    - The subcommand tree in Sources/acp-agent is exactly the tree the card names: `run` (the default), `acp`, `config show|init|path|edit`, `instructions eject`, `doctor`.
    - `doctor` exists and exits 0, 1 or 5, but `Doctor.components(workingDirectory:environment:)` returns an empty list today: it runs NO check. Later cards add the checks.

    One deviation from the card text, recorded here: the card asks the README to say that `acp-agent doctor` "reports the size before you start". `doctor` cannot report a download size today, because it runs no check. The README must not state a check that does not run, so it says the first run downloads the models, names `doctor` as the command that checks the configuration, and says the profile checks are not written yet. The card acceptance criteria do not name the size claim.
  timestamp: 2026-09-09T01:57:02.900704+00:00
- actor: claude-code
  id: 01m21yqgc4r2s71s6jg01tkyt1
  text: |-
    ### implement — changed
    - evidence: 2 files — README.md (new sections "The machine, and the models" and "Command line"), Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift (three new cases, and one shared `readmeText()` helper the six cases now use). `swift test`: 511 tests in 53 suites passed, 1 known issue at HarnessSmokeTests.swift:239 (the baseline). Baseline was 508 tests, so the three new cases are the difference. `swift test --filter DocumentationSyncTests`: 6 tests passed. Red first: the three new cases failed with 14 issues before the README changed. `git diff plan.md` is empty. No compiler warning.
    - The command test walks `AcpAgentCommand.configuration.subcommands`, so a new subcommand joins the list on the day it ships and fails until the README documents it.
    - next: /review
  timestamp: 2026-09-09T02:07:40.932941+00:00
- actor: claude-code
  id: 01m21z06p36breyr32bjj0j0px
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (ab87e9e). 0 findings, 0 confirmed, 0 refuted, 7 validator runs, 0 failed. The engine read the diff of Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift. README.md matched no validator, and the .kanban files are excluded by .reviewignore.
    - deviation: the card asked the README to say that `acp-agent doctor` reports the download size. The README does not say it, because `Doctor.components(workingDirectory:environment:)` gives an empty list today. The reviewer accepts this deviation: a README that names a check which does not run would be incorrect. The size check stays with card ^mm476zb.
    - note: the description writes the target card as `^m476zb`. The correct short id is `^mm476zb` (01M1MP4P9CJW36PD0EKMM476ZB).
    - next: card moved to done.
  timestamp: 2026-09-09T02:12:25.923934+00:00
- actor: claude-code
  id: 01m21z0snqdce6f3986rt1bdh9
  text: |-
    ### finish iteration — clean
    - implement: changed — 2 files. README.md gained "The machine, and the models" (the 32 GB floor with its reason, and the three `ProfileConfiguration` slot defaults) and "Command line" (one row per command, each abstract from the command's own `CommandConfiguration`). `DocumentationSyncTests.swift` gained three cases that read the facts from the code, so a new subcommand or a changed default makes the test fail until the README agrees.
    - test: green — swift test, 511 tests in 53 suites, 1 known issue at HarnessSmokeTests.swift:239. It was 508 before this card.
    - commit: ab87e9e
    - review: clean — 0 findings, 7 validator runs
    - deviation, accepted by the review: the card asked the README to say `doctor` reports the download size before you start. The README does not say that, because `Doctor.components(...)` gives an empty list today and the command runs no check. A README that named the size report would state a check that does not run. The size check belongs to card `^mm476zb`.
    - correction: an earlier note on this card wrote the follow-on card as `^m476zb`. The true short id is `^mm476zb`.
  timestamp: 2026-09-09T02:12:45.367808+00:00
depends_on:
- 01M1MNYZXP3TFQPKTCAK4RQ6AB
- 01M1MP3120PZBY1VSH0GC7QQ26
- 01M1MP26DWFVPD94A6JHSHTV5V
- 01M1MP2M9PNERHG16X7A0SG4JN
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: done
position_ordinal: c780
title: 'README: document the CLI surface, the models and the 32 GB floor'
---
### What

**Correction to the earlier framing.** `README.md` (103 lines) contains
**no** "16 GB" figure and **no** Qwen model name. Only `plan.md:191`
carries the 16 GB figure, and this card does not edit `plan.md`. So
there is nothing to correct — this is an **addition**.

cli-plan.md §7 gives the new default profile and a 32 GB floor, and
§5.3 gives a command surface that the README never mentions. A person
reads the README before anything else, and today it tells them neither
what the binary can do nor what machine it needs.

In `README.md`:

- [x] State the memory floor: **32 GB**, and why — the default trio is
      priced against the machine's memory by Router's `JointFit`.
- [x] Name the three default models of §7, with their slots.
- [x] Add the `acp-agent` command surface: `run`, `acp`, `config show |
      init | path | edit`, `instructions eject`, `doctor` — one line
      each.
- [x] Say that the first run downloads the models, and that
      `acp-agent doctor` reports the size before you start. The README
      says the first run downloads the weights, and names `doctor` as
      the command that checks a configuration. It does NOT say that
      `doctor` reports the size: `Doctor.components(...)` gives an empty
      list today, thus the command runs no check. The README says that
      too. The size check belongs to card `^m476zb`.

**`plan.md` is not edited.** cli-plan.md §12 records which document
governs each item, on purpose.

### Acceptance Criteria

- [x] `README.md` names all three default model ids, and they equal the
      `ProfileConfiguration` statics exactly.
- [x] `README.md` states 32 GB.
- [x] Every subcommand name of the §5.3 tree appears in `README.md`.
- [x] `git diff plan.md` is empty.

### Tests

- [x] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift`
      gains a case: every model reference the README names equals the
      matching default in `ProfileConfiguration`. A future default
      change with no README change fails the test.
- [x] The same test asserts the README holds the string "32 GB".
- [x] A test asserts every subcommand name of the command tree appears
      in `README.md`, so a new subcommand cannot ship undocumented.
- [x] `swift test --filter DocumentationSyncTests` passes.

### Ordering

This card runs **after** every subcommand it documents, so the README
does not describe stubs that exit 1.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.