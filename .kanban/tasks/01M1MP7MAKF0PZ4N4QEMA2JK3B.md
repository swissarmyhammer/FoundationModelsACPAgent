---
assignees:
- claude-code
depends_on:
- 01M1MNYZXP3TFQPKTCAK4RQ6AB
- 01M1MP3120PZBY1VSH0GC7QQ26
- 01M1MP26DWFVPD94A6JHSHTV5V
- 01M1MP2M9PNERHG16X7A0SG4JN
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: todo
position_ordinal: '9480'
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

- [ ] State the memory floor: **32 GB**, and why — the default trio is
      priced against the machine's memory by Router's `JointFit`.
- [ ] Name the three default models of §7, with their slots.
- [ ] Add the `acp-agent` command surface: `run`, `acp`, `config show |
      init | path | edit`, `instructions eject`, `doctor` — one line
      each.
- [ ] Say that the first run downloads the models, and that
      `acp-agent doctor` reports the size before you start.

**`plan.md` is not edited.** cli-plan.md §12 records which document
governs each item, on purpose.

### Acceptance Criteria

- [ ] `README.md` names all three default model ids, and they equal the
      `ProfileConfiguration` statics exactly.
- [ ] `README.md` states 32 GB.
- [ ] Every subcommand name of the §5.3 tree appears in `README.md`.
- [ ] `git diff plan.md` is empty.

### Tests

- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift`
      gains a case: every model reference the README names equals the
      matching default in `ProfileConfiguration`. A future default
      change with no README change fails the test.
- [ ] The same test asserts the README holds the string "32 GB".
- [ ] A test asserts every subcommand name of the command tree appears
      in `README.md`, so a new subcommand cannot ship undocumented.
- [ ] `swift test --filter DocumentationSyncTests` passes.

### Ordering

This card runs **after** every subcommand it documents, so the README
does not describe stubs that exit 1.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.