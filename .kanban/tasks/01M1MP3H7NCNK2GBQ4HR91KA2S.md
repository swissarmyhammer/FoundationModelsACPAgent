---
assignees:
- claude-code
depends_on:
- 01M1MNXE777J4XA3NJTP483A8W
- 01M1MNXY19R8HPEMNGF2WXB0G6
- 01M1MNYFW81216M57PS9NDZKBE
- 01M1MP13QK1NX440VP88F7NQYA
position_column: todo
position_ordinal: 8d80
title: 'doctor subcommand: run the checks, render the report, exit 0, 1 or 5'
---
### What

cli-plan.md §5.12. `doctor` answers one question: will this
configuration actually work? This card builds the command and the
rendering. The checks are three later cards.

In `Sources/acp-agent/DoctorCommand.swift`:

- Collect this package's `Doctorable` components through a registry
  function, run them through the Extras `DoctorRunner`, and render the
  `DoctorReport`.
- **Two rendering paths, and this resolves a contradiction in the
  plans.** `TerminalRenderer` is silent when its destination is not a
  terminal, but doctor-plan §6 requires "a pipe gets plain text, in a
  stable, testable form". A silent renderer cannot produce a piped
  table. So:
  - stderr **is** a terminal → draw the table through
    `TerminalRenderer`, with color and box drawing.
  - stderr is **not** a terminal → write the **Extras plain-text
    renderer** output. Plain text, no ANSI escape, still on stderr.
  The doctor table is therefore carved out of the silent-on-pipe rule,
  and the carve-out is deliberate: a diagnostic that vanishes in a pipe
  is useless in CI.
- `--json` writes the report to **stdout** as one JSON array.
- Exit 0 for all `.ok`, 1 for any `.error`, 5 for warnings with no
  error.
- It honors `--cwd`.

Register an empty component list here. Each later card appends its own
conformance to the registry, so this command never changes again.

- [ ] `DoctorCommand`, over the Extras runner
- [ ] The terminal path and the plain path, both on stderr
- [ ] `--json` to stdout
- [ ] The three exit codes, from the shared `ExitCode` enum
- [ ] A registry function the later cards append to
- [ ] Refresh and commit `Package.resolved`, so the new Extras
      `Doctorable` surface is visible — a `main` branch dependency stays
      pinned by revision until `swift package update` runs

### Acceptance Criteria

- [ ] With an empty component list, `doctor` exits 0 and prints an empty
      report.
- [ ] A stub component reporting `.error` exits 1; warnings only exits 5.
- [ ] With a non-terminal stderr, the output is non-empty **and** holds
      no `ESC[` sequence.
- [ ] With a terminal stderr, the output is drawn through
      `TerminalRenderer`.
- [ ] `--json` goes to stdout; the table never does.
- [ ] `Package.resolved` names an Extras revision that carries
      `Doctorable`.

### Tests

- [ ] `DoctorCommandTests`: inject stub components and assert the exit
      code of each of the three cases.
- [ ] With an injected non-terminal destination, the plain output is
      non-empty and holds no `ESC[`.
- [ ] With an injected terminal destination, the table is drawn.
- [ ] A test asserts the human table goes to stderr and never to stdout,
      and that `--json` does the reverse.
- [ ] The `--json` output decodes to the same checks.
- [ ] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.