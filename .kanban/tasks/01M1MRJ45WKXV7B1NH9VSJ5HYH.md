---
assignees:
- claude-code
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: todo
position_ordinal: '9980'
title: 'doctor checks: the skills stack, and the Metal runtime question'
---
### What

cli-plan.md §5.12, the Skills and Runtime rows. Split out of the tools
card.

`RuntimeDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`runtime`:

- **The skills stack is found.** `DotfolderStack(name: "skills")`
  resolves, and the layers that exist are readable. A missing stack is
  `.ok` — skills are optional — and an unreadable one is an `.error`.

**The Metal library check needs a definition before it can be built.**

cli-plan.md §5.12 says "The Metal shader library stands beside the
binary", but this repository has no `.metal` source and no checked-in
`.metallib`. The only colocation machinery is Router's
`MetalLibraryTestBootstrap`, reached solely from the nested integration
package, and it symlinks the library **in process, for tests only**.
`CIWorkflowTests.swift` records that this is why the
`integration-metallib-glob` CI knob is unnecessary. So the check has no
defined filename, no defined install location, and no artifact that
ships with an installed binary.

**Answer these three before writing the check**, and record the answers
in a task comment:

1. What is the exact library filename? (Read what
   `MetalLibraryTestBootstrap` looks for.)
2. Where must it stand, relative to an **installed** `acp-agent`?
3. What produces it there — mlx-swift's own bundle resource, or nothing
   at all?

If the answer to 3 is "nothing" — that is, an installed binary finds the
library through mlx-swift's resource bundle and never needs a sibling
file — then **drop the row** and say so in the comment. A check that
asserts against an invented target is worse than no check.

- [ ] The skills stack check
- [ ] Answer the three Metal questions in a task comment
- [ ] Write the Metal check, or drop the row with the reason recorded
- [ ] Register the component in the doctor list

### Acceptance Criteria

- [ ] A missing skills stack gives `.ok`; an unreadable one gives an
      `.error` with a fix.
- [ ] The task comment answers all three Metal questions.
- [ ] If the Metal row survives, it names an exact filename and an exact
      path, and a fixture directory drives both the present and the
      absent case.
- [ ] If it is dropped, the comment says why, and cli-plan §5.12's
      Runtime row is noted as superseded.
- [ ] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

- [ ] `RuntimeDoctorTests`: the skills-present, skills-absent and
      skills-unreadable cases, against a temporary stack.
- [ ] If the Metal row survives: the library-present and library-absent
      cases, against a temporary directory — never against the real
      machine, so the test is reproducible in CI.
- [ ] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.