---
assignees:
- claude-code
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: todo
position_ordinal: 8c80
title: 'instructions eject: write Instructions.md into a layer'
---
## What

cli-plan.md §5.3 lists `acp-agent instructions eject`, and no milestone
covered it. This task closes that gap.

`plan.md` §3.1 makes `Instructions.md` a compiled-in floor that a file in
the user or the project layer replaces **wholesale**, nearest layer
wins. A person cannot edit what they cannot see, so the CLI writes the
compiled-in text out for them.

In `Sources/acp-agent/InstructionsCommands.swift`:

```
acp-agent instructions eject [--user|--project] [--force]
```

- It writes the compiled-in `Instructions.md` into the chosen layer.
  `--project` is the default, matching `config init`.
- It refuses to overwrite an existing file, and it exits 1 with a
  message that names `--force`.
- It prints the path it wrote, to stdout.
- It honors `--cwd`.

The plan spells this `instructions eject`, and not
`instructions --eject` as `plan.md` §3.1 writes it, so that every
subcommand group reads the same way.

- [ ] `instructions eject`, with `--user`, `--project` and `--force`
- [ ] Reuse the same overwrite guard as `config init`
- [ ] Print the written path to stdout

## Acceptance Criteria

- [ ] After an eject, the assembler reads the written file in place of
      the compiled-in text, and the two are equal.
- [ ] A second eject without `--force` exits 1 and changes no file.
- [ ] The written path goes to stdout, and the refusal goes to stderr.
- [ ] `--cwd` selects which project layer receives the file.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsEjectTests.swift`:
      eject into a temporary stack, then assert that the instruction
      assembler's result is unchanged — the ejected file is byte-equal
      to the compiled-in floor.
- [ ] Edit the ejected file, and assert the assembler now returns the
      edited text. This proves the wholesale-replace rule end to end.
- [ ] The refuse-to-overwrite path, and the `--force` path.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.