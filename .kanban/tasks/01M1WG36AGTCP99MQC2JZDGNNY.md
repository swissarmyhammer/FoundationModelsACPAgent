---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21hz5k8qfewhcxe9deq08bm
  text: |-
    ### The upstream card is made

    `FoundationModelsACPClient` card **`^vs86g2a`** — "cli-plan §5: reconcile "a progress bar and a table" with the one terminal file". It is in `todo` and carries the full specification of this card.

    Note that the first subtask of that card asks for a DECISION with a person, between the two ways out. It is not work an agent can close on its own.

    This card stays open until that one is done and merged to ACPClient `main`.
  timestamp: 2026-09-08T22:24:40.552575+00:00
- actor: claude-code
  id: 01m21x25r56qsnyt7gqgbz0fwc
  text: |
    ### What landed upstream, and what did not

    The upstream card `^vs86g2a` in `FoundationModelsACPClient` is done and
    merged. The change is commit `1afd74a`, "docs(cli-plan): name the spinner
    in section 5, not a table".

    **It took way 1 — narrow the sentence.** §5 of `cli-plan.md` on ACPClient
    `main` now reads: `TerminalOutput.swift` vends the spinner of §8, through
    `withSpinner(_:_:)`; a component reaches this layer when a caller needs
    it, and not before; a table has no caller, because §8 sends the `probe`
    report and the `doctor` report to stdout, and this layer writes to stderr
    only; a progress bar has no total to show. §8 is unchanged, because way 1
    does not touch it.

    **Verified in the source, not only in the document:**

    - `Sources/AcpClientCore/TerminalOutput.swift` vends `withSpinner(_:_:)`,
      `event(_:)`, `frame(_:)`, `error(_:)` and the `logger` bridge. There is
      no table type and no progress-bar type. The card's rule — do not write
      an unused type to make the sentence true — holds.
    - `Tests/FoundationModelsACPClientTests/TerminalOutputTests.swift` covers
      the spinner, the one component the new §5 names: it draws in a terminal,
      writes nothing outside one, writes nothing at `--quiet`, returns the
      body value, and rethrows the body error.

    **A person did NOT decide.** The finish ledger of `^vs86g2a` says it
    plainly: the row "Decide between the two ways out, with a person" is
    ticked under the recorded assumption of the finish step, and not on a
    decision by a person. If a person prefers way 2, open a new card. The
    change of way 1 is one paragraph, and it is easy to reverse.

    **So this card stays open.** The decision row here is unticked. The card
    waits on the user, who must choose between way 1, which stands in the
    merged document, and way 2, which gives the table a caller and changes §8
    and the `--json` row of §6.1.

    The `swift test` row is also unticked. The upstream card ran the suites,
    but this step did not run them, because the instruction for this step
    forbids the IntegrationTests package. The row records what this board
    verified, and this board did not verify it.

    No file in this repository changed for this card, except the card itself.
    No file in `../FoundationModelsACPClient` was touched; it was read only.
  timestamp: 2026-09-09T01:38:33.349639+00:00
- actor: claude-code
  id: 01m21x2b98n224jtegbyz55qq1
  text: |
    ### implement — stuck

    - evidence: read `cli-plan.md` §5 and
      `Sources/AcpClientCore/TerminalOutput.swift` on ACPClient `main` at
      commit `1afd74a`. The document and the file agree: the file vends the
      spinner alone, and no unused table type or progress-bar type stands.
      `TerminalOutputTests.swift` covers the spinner. Ticked three subtask
      rows and two acceptance rows. Left "Decide between the two ways out,
      with a person" unticked, because no person decided; left the
      `swift test` row unticked, because this step did not run the suites.
      No source file changed in this repository.
    - next: the user chooses way 1 or way 2. If way 1, tick the decision row
      and the test row after a suite run. If way 2, open a new card in
      `FoundationModelsACPClient` to give the table a caller and to change §8
      and the `--json` row of §6.1.
  timestamp: 2026-09-09T01:38:39.016683+00:00
position_column: doing
position_ordinal: '80'
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
- [x] Change `cli-plan.md` §5, and §8 as well if way 2 wins
- [x] Make the code match the decision

### Acceptance Criteria

- [x] `cli-plan.md` §5 and the terminal file agree on what the file vends.
- [x] No type stands in `TerminalOutput.swift` that no caller uses.
- [ ] `swift test` in `../FoundationModelsACPClient` passes, and
      `swift test --package-path IntegrationTests` passes with it.

### Tests

- [x] `TerminalOutputTests` covers each component the decided §5 names.

### Open

The decision row stays open. Way 1 landed upstream, but an agent took it
under a recorded assumption. A person did not decide. See the comments.
