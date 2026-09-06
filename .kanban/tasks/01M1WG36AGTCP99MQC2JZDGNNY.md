---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
title: 'acp-client cli-plan §5: reconcile "a progress bar and a table" with the one terminal file'
---
### What

In `../FoundationModelsACPClient`, `cli-plan.md` §5 says the one file that
imports Noora "vends a spinner, a progress bar and a table". The written
file, `Sources/AcpClientCore/TerminalOutput.swift`, vends the spinner
alone, through `withSpinner(_:_:)`.

The two cannot both stand, and the difference is not an oversight:

- §5 and §8 hold this layer to **stderr**, and they let it draw only when
  stderr is a terminal.
- The only reports a table would draw are the `probe` report and the
  `doctor` report, and §8 sends both to **stdout**, because each report IS
  the output of its run.
- So a table on this layer has no caller today, and a progress bar has no
  total to show: §8 gives the wait before the first answer chunk a plain
  spinner, because the client cannot know what the agent is doing.

A person must decide which document is correct. Do NOT write an unused
type to make the sentence true.

Two ways out, and the card asks for a decision between them:

1. **Narrow the sentence.** §5's rule is the containment rule — one file
   imports Noora — and the list of components is an example of the
   surface, not a promise. Rewrite the sentence to name the spinner, and
   say that a component reaches this layer when a caller needs it.
2. **Give the table a caller.** Decide that `probe` and `doctor` draw
   their human-readable report through this layer, and change §8 to say
   which descriptor that report goes to. This is the larger change, and it
   touches the `--json` row of §6.1 as well.

Found while finishing ^cfkr6vw. That card left the code as it stands and
recorded this, rather than adding a type with no caller.

- [ ] Decide between the two ways out, with a person
- [ ] Change `cli-plan.md` §5, and §8 as well if way 2 wins
- [ ] Make the code match the decision

### Acceptance Criteria

- [ ] `cli-plan.md` §5 and the terminal file agree on what the file vends.
- [ ] No type stands in `TerminalOutput.swift` that no caller uses.
- [ ] `swift test` in `../FoundationModelsACPClient` passes, and
      `swift test --package-path IntegrationTests` passes with it.

### Tests

- [ ] `TerminalOutputTests` covers each component the decided §5 names.
