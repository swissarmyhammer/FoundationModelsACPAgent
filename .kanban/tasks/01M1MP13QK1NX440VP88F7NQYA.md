---
assignees:
- claude-code
depends_on:
- 01M1MP0MQ6VHRR004FQQEADS6C
position_column: todo
position_ordinal: '8880'
title: 'Exit codes: one table for every stop reason and failure'
---
## What

cli-plan.md §5.8. "Nonzero" is not enough for a script. Add
`Sources/acp-agent/ExitCode.swift` with one enum, and use it at every
exit.

| Code | Meaning |
|---|---|
| 0 | `end_turn`, or a report that ran |
| 1 | An error: configuration, spawn, protocol, or I/O. `doctor` found an error. |
| 2 | A usage error |
| 3 | `refusal` |
| 4 | `cancelled` |
| 5 | `doctor` found warnings, and no error |

**Code 124 is not in the agent's table.** cli-plan §5.8 lists it, but
§5.4 gives `run` no `--timeout` option, so no code path can produce it.
An acceptance criterion of "one assertion per row" would be
unsatisfiable. 124 stays in the **client** CLI's table, where
`--timeout` exists. This card supersedes that row of §5.8 for the agent.

Map each `StopReason` of the wire to its code in **one total switch**,
with no `default` case, so a new stop reason upstream makes the build
fail rather than silently exiting 0. ArgumentParser's own usage error
maps to 2.

The reason line goes to **stderr**, never to stdout.

**This card lands before the exit-producing cards.** The progress card
adds a resolution-failure path and the doctor card adds 1 and 5; both
depend on this enum existing, so both list it as a dependency.

- [ ] `ExitCode.swift`, with the six cases
- [ ] A total switch over `StopReason`, with no `default`
- [ ] The ArgumentParser usage error maps to 2
- [ ] Every exit path in `Run` and `Acp` uses the enum

## Acceptance Criteria

- [ ] A scripted `end_turn` gives 0, `refusal` gives 3, `cancelled`
      gives 4.
- [ ] An unknown flag gives 2, with stdout empty.
- [ ] A configuration that fails to load gives 1, with the reason on
      stderr.
- [ ] The `StopReason` switch has no `default` case.
- [ ] The enum declares no 124 case in this package.

## Tests

- [ ] `ExitCodeTests`: one assertion per row of the six-row table,
      driven through the scripted model where a stop reason is
      necessary.
- [ ] A test asserts stdout is empty for each nonzero exit.
- [ ] A compile-time proof that the `StopReason` switch is total: adding
      a case to the wire enum must break the build, not the behavior.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.