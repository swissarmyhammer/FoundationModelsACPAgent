---
assignees:
- claude-code
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: todo
position_ordinal: 8b80
title: config init and config edit, sharing one writer with /config export
---
## What

cli-plan.md §5.11. `config show` reads; these two write.

**There is already a generator — do not write a second one.**
`Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift`
emits the commented block YAML that `/config export` writes, and its own
doc comment records that the text round-trips through
`ConfigurationLoader`. This card **calls that type**; it does not
extract a new `ConfigurationWriter`.

**`config init`** writes a `config.yaml` with every key at its default,
each under a comment.

- `--user` writes the user layer, `--project` the project layer.
  `--project` is the default.
- It refuses to overwrite an existing file, exits 1, and names
  `--force`. `--force` overwrites.
- It prints the path it wrote, to stdout.

**The layer names differ between the two front doors, and the mapping
must be stated.** `/config export` takes `home|project`
(`BuiltinCommands.swift`: `configUsage = "Usage: /config export
home|project"`), while `config init` takes `--user|--project`. Map
`--user` ↔ `home` in one place, and say so in the code, so a reader is
not left guessing whether they are two layers or one.

**`config edit`** opens the nearest `config.yaml` in `$EDITOR`. With no
file in any layer it runs the `config init` path first and says so on
stderr. With no `$EDITOR` it exits 1 and names the variable.

- [ ] `config init` over the existing `ConfigurationYAML`
- [ ] `--user`, `--project`, `--force`, and the `home` mapping
- [ ] `config edit`, with the missing-file and missing-`$EDITOR` paths
- [ ] No new generator type

## Acceptance Criteria

- [ ] `config init` writes a file that `ConfigurationLoader` reads back
      to exactly `AgentConfiguration()`.
- [ ] Every top-level section and every key of the schema appears in the
      generated file.
- [ ] A second `config init` without `--force` exits 1 and changes no
      file.
- [ ] `config edit` with no `$EDITOR` exits 1 and names the variable.
- [ ] `config init --user` and `/config export home` write
      byte-identical files to the same path.
- [ ] No file named `ConfigurationWriter.swift` is added.

## Tests

- [ ] `ConfigInitTests`: write into a temporary stack, load it back, and
      assert equality with `AgentConfiguration()`.
- [ ] A test walks `AgentConfiguration.sectionSchemas` and asserts each
      known key appears in the generated text. A new key with no comment
      fails the test.
- [ ] The refuse-to-overwrite path, and the `--force` path.
- [ ] A test asserts `config init --user` and `/config export home`
      produce byte-identical output.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.