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
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: todo
position_ordinal: 9c80
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

- [ ] Declare and pin Noora at an exact version; record the version
- [ ] `TerminalRenderer`, with the injected destination and terminal flag
- [ ] Spinner, bar and table
- [ ] No other file under `Sources/acp-agent/` imports Noora

### Acceptance Criteria

- [ ] `swift build` succeeds on macOS 27 with Noora linked at the pinned
      version.
- [ ] With `isTerminal: false`, each of the three renderers writes zero
      bytes to the destination.
- [ ] With `isTerminal: true` and a `Pipe` destination, each of the
      three writes a non-empty payload.
- [ ] The renderer never writes to file descriptor 1.
- [ ] `TerminalRenderer.swift` is the only file under
      `Sources/acp-agent/` that holds `import Noora`.

### Tests

- [ ] `Tests/FoundationModelsACPAgentTests/TerminalRendererTests.swift`:
      with `isTerminal: false` and a `Pipe`, the spinner, the bar and
      the table each write zero bytes.
- [ ] With `isTerminal: true` and a `Pipe`, each writes a non-empty
      payload. This automates the terminal path with no pseudo-terminal.
- [ ] A test captures file descriptor 1 during a full render and
      asserts it stayed empty.
- [ ] A source-level test asserts `import Noora` appears in exactly one
      file under `Sources/acp-agent/`.
- [ ] `swift test --filter TerminalRendererTests` passes.
- [ ] `swift build` passes with no warning.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.