---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1y1xe1m8pxd8frh3n4ncqqj
  text: |
    ### the partial work is in a git stash

    A sub agent started this card and was stopped. It left three files in the working tree:

    - `Package.swift` — the Noora dependency and the `nooraProduct` target dependency.
    - `Tests/FoundationModelsACPAgentTests/Support/TerminalCapture.swift`
    - `Tests/FoundationModelsACPAgentTests/TerminalRendererTests.swift`

    `TerminalRendererTests.swift` tests `TerminalRenderer`, and that type was never written: `Sources/acp-agent/Terminal/` does not exist. Thus the test target does not compile, and no other card can run a test.

    The three files are now in a git stash, so no line is lost:

    ```
    stash@{0}: On main: ^2wxb0g6 Noora WIP: TerminalRenderer never written, test target does not compile
    ```

    Get them back with `git stash pop` (or `git stash apply`) when this card starts again. Read `TerminalRendererTests.swift` first: it states the shape the renderer must have.
  timestamp: 2026-09-07T13:46:23.156101+00:00
- actor: claude-code
  id: 01m1ykabxw6ys3pq8tptn46z5e
  text: |
    ### the stash came back clean, and the Noora pin is 0.57.0

    `git stash pop` applied with no conflict. It gave back `Package.swift`, `Tests/FoundationModelsACPAgentTests/Support/TerminalCapture.swift` and `Tests/FoundationModelsACPAgentTests/TerminalRendererTests.swift`.

    **The pinned version is `0.57.0`, exactly.** `git ls-remote --tags https://github.com/tuist/Noora.git` shows 0.57.0 is the newest numeric release. It builds and links here on macOS 27 with swift-tools-version 6.2. The client package must pin the same string:

    ```swift
    .package(url: "https://github.com/tuist/Noora.git", exact: "0.57.0")
    ```

    ### what the Noora API gives, and what it does not

    Read from `.build/checkouts/Noora/cli/Sources/Noora/`:

    - Each component writes only through `StandardPipelines`. A pipeline is a `StandardPipelining` value the caller gives. So a renderer can send every byte to one file handle, and no byte reaches file descriptor 1.
    - `Terminal(isInteractive:isColored:signalBehavior:)` takes the terminal test as an argument. **Use `signalBehavior: .none`.** The default, `.restoreAndExit`, puts handlers on SIGINT, SIGTERM, SIGQUIT and SIGHUP that call `exit(0)`. That would take the interrupt away from `InterruptHandler`.
    - `progressStep(message:successMessage:errorMessage:showSpinner:task:)` gives the spinner. It draws once at the start, and again on each report. The report takes a `String`.
    - **`progressBarStep` cannot carry the byte pair.** Its message is fixed at the call, its report takes only a `Double`, and it draws only when the 0.1 s spinner timer ticks. A fast task can end before the first tick. So the bar goes through the step channel instead: the renderer composes the bar, the percentage and the byte pair into one line and reports that line. The step channel draws on each report.
    - `table(headers: [TableCellStyle], rows: [StyledTableRow])` gives the table with a colored status column: `.success`, `.warning` and `.danger`.

    ### the byte text is hand-formatted, and this is why

    `ByteCountFormatter` gives `1 MB` and `4 MB` for 1 MiB and 4 MiB, in every one of its four count styles. The test asks for `1.0 MB / 4.0 MB`. So `TerminalRenderer.byteText(_:)` steps by 1024 and prints one decimal above the byte unit.
  timestamp: 2026-09-07T18:50:32.764298+00:00
- actor: claude-code
  id: 01m1yks2pnxr31f3eqa60b0cvx
  text: |
    ### the renderer is written, and the rules of the review are applied

    `Sources/acp-agent/Terminal/TerminalRenderer.swift` is new. It is a `Sendable` struct with two stored properties, `destination: FileHandle` and `isTerminal: Bool`, and it vends three things:

    - `spinner(message:work:)`
    - `progressBar(message:work:)`, whose report takes a `Double` fraction and a `ByteProgress`
    - `table(statusHeader:columnHeaders:rows:)`, whose rows carry a `Status` of `ok`, `warning` or `failure`

    Each of the three opens with `guard isTerminal else { … }`. On that path the work still runs and the renderer writes no byte. On the terminal path a `FileHandlePipeline` sends both halves of Noora's `StandardPipelines` to `destination`, so nothing reaches file descriptor 1.

    ### what the rules of `dump validators` changed

    - `disallowed-constructs-swift` and `swiftformat` idioms: the file is clean.
    - **Three memberwise initializers were removed** — swiftlint `unneeded_synthesized_initializer` named `TerminalRenderer.init(destination:isTerminal:)`, `ByteProgress.init(completed:total:)` and `Row.init(status:cells:)`. Each was the same as the synthesized one. Swift synthesizes all three, so the shape the card asks for, `init(destination: FileHandle, isTerminal: Bool)`, stands. The text of the removed doc comments moved onto the two stored properties.
    - `duplication`: `spinner` and `progressBar` both called Noora with the same four arguments. One private `step(message:showSpinner:task:)` is now the only call into Noora's step channel.
    - `duplication`: one private `plainCells(_:)` makes the header cells and the row cells.
    - `naming-clarity`: `held` became `heldFraction`.
    - `reuse`: the doc comment of `byteText(_:)` now says why `ByteCountFormatter` cannot do the work.

    The one swiftlint line that stands is `identifier_name` on `case ok`, which asks for three characters. That rule is not in the twelve of `disallowed-constructs-swift`, and `.ok` is the name the test states.

    ### the state of the card

    Every checklist item and every acceptance criterion is `- [x]`, and each is true.
  timestamp: 2026-09-07T18:58:34.837098+00:00
- actor: claude-code
  id: 01m1yks8cryt6pn6y48rww3edy
  text: |
    ### implement — changed

    - evidence: 3 files — `Package.swift` (Noora pinned at `exact: "0.57.0"`), `Sources/acp-agent/Terminal/TerminalRenderer.swift` (new), and the two recovered test files `Tests/FoundationModelsACPAgentTests/TerminalRendererTests.swift` and `Tests/FoundationModelsACPAgentTests/Support/TerminalCapture.swift`. `swift test --filter TerminalRendererTests`: 9 tests, all pass. `swift test` three times in sequence: 437 tests in 46 suites, each run with exactly one known issue, the `withKnownIssue` at `HarnessSmokeTests.swift:239`. `swift build`: no source warning; the only line is the build-system `missing creator for mutated node` for the mlx bundle.
    - next: `/review`
  timestamp: 2026-09-07T18:58:40.664339+00:00
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: doing
position_ordinal: '80'
title: Adopt Noora, and write the agent CLI's TerminalRenderer
---
### What

cli-plan.md §5.2. swift-argument-parser covers clap; **Noora** (Tuist)
covers indicatif, dialoguer, comfy-table and owo-colors in one CLI
design system. Adopt it.

This card delivers the **agent** package's renderer only. The client
package declares and writes its own, in its N1 card, because the two
packages must not depend on each other.

1. Declare `https://github.com/tuist/Noora` in `Package.swift`, pinned
   to an **exact version**. Resolve the newest release that builds on
   macOS 27 with swift-tools-version 6.2, and write that version into
   `Package.swift` and into a task comment, so the client package pins
   the same one.
2. `Sources/acp-agent/Terminal/TerminalRenderer.swift` — the one place
   any CLI code draws. It vends three things and nothing more: a
   spinner, a progress bar that takes a fraction and a byte pair, and a
   table of rows with a status column.
3. **Both the destination and the terminal test are injected**, not read
   from process globals:
   ```swift
   init(destination: FileHandle, isTerminal: Bool)
   ```
   The production call site passes `.standardError` and
   `isatty(STDERR_FILENO) == 1`. A test drives **both** paths with a
   `Pipe` and an explicit boolean, so the terminal path is automated and
   needs no person to look at a screen.
4. The renderer writes to its destination only. It never touches file
   descriptor 1.

Every later task that draws — the download progress, `doctor` and the
`--verbose` events — calls this type. None imports Noora.

- [x] Declare and pin Noora at an exact version; record the version
- [x] `TerminalRenderer`, with the injected destination and terminal flag
- [x] Spinner, bar and table
- [x] No other file under `Sources/acp-agent/` imports Noora

### Acceptance Criteria

- [x] `swift build` succeeds on macOS 27 with Noora linked at the pinned
      version.
- [x] With `isTerminal: false`, each of the three renderers writes zero
      bytes to the destination.
- [x] With `isTerminal: true` and a `Pipe` destination, each of the
      three writes a non-empty payload.
- [x] The renderer never writes to file descriptor 1.
- [x] `TerminalRenderer.swift` is the only file under
      `Sources/acp-agent/` that holds `import Noora`.

### Tests

- [x] `Tests/FoundationModelsACPAgentTests/TerminalRendererTests.swift`:
      with `isTerminal: false` and a `Pipe`, the spinner, the bar and
      the table each write zero bytes.
- [x] With `isTerminal: true` and a `Pipe`, each writes a non-empty
      payload. This automates the terminal path with no pseudo-terminal.
- [x] A test captures file descriptor 1 during a full render and
      asserts it stayed empty.
- [x] A source-level test asserts `import Noora` appears in exactly one
      file under `Sources/acp-agent/`.
- [x] `swift test --filter TerminalRendererTests` passes.
- [x] `swift build` passes with no warning.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.