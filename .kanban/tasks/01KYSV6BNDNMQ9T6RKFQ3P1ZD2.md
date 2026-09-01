---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fejrzdxvkhqk9vjqbqkhb6
  text: |-
    Research notes:
    - `DotfolderStack.content(_:)` gives text only, with no layer. The assembler finds the winning layer with `nearest(_:)` and a root match, and it derives trust in one private helper: `nil` (the builtin floor) and `.defaults` are trusted, `.user` and `.project` are untrusted.
    - `content(_:)` gives `nil` for a missing file and also for a file that does not decode as UTF-8. The pair `nearest != nil` with `content == nil` identifies the "present but unreadable" case without a second read.
    - `AgentsMd.documents(from:)` throws `AgentsMdError.fileNotReadable` for the full walk. The assembler catches it, appends a `fileUnreadable` warning, and continues with no project documents.
    - The builtin prompt stays self-contained (no `{% include %}`). A compiled-in include of a missing partial would break the no-files case. The partial-layering criterion is proven with a user-layer `Instructions.md` that includes `style`, and a project `_partials/style.md` that shadows only the partial.
    - `preloadedBodies()` reads the current catalog snapshot. The assembler calls it at each `assemble`, so a `watch: true` registry shows a disk edit in the next assembly. The test proves it with a poll loop.
    - Unreadable-file fixtures use invalid UTF-8 bytes, not `chmod`, so the tests also run as root.
  timestamp: 2026-09-01T21:39:08.909180+00:00
- actor: claude-code
  id: 01m1fejtz7tj3e4gvm9nezkwhw
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Instructions/BuiltinInstructions.swift, Sources/FoundationModelsACPAgent/Instructions/InstructionsAssembler.swift, Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift, Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift, README.md
    - next: test
  timestamp: 2026-09-01T21:39:10.951802+00:00
- actor: claude-code
  id: 01m1fekbg45cyxaekc2dzkdj32
  text: |-
    ### test — green
    - evidence: swift test — 65 passed, 0 failed, 0 skipped; swift build --build-tests — 0 warnings
    - next: commit
  timestamp: 2026-09-01T21:39:27.876377+00:00
- actor: claude-code
  id: 01m1feksvg9vtcvsfz23p8s4kv
  text: |-
    ### commit — changed
    - evidence: c6589b6 feat(instructions): add the builtin floor, the wholesale-replacement assembler and the AGENTS.md walk
    - next: review
  timestamp: 2026-09-01T21:39:42.576667+00:00
- actor: claude-code
  id: 01m1fes05js2eape52hc4tq43k
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 0 refuted; 4 files reviewed
    - next: done
  timestamp: 2026-09-01T21:42:32.882426+00:00
- actor: claude-code
  id: 01m1fes5efer11sx19ym0h6m1a
  text: |-
    ### finish iteration 1 — done
    - implement: changed
    - test: green (65 passed, 0 failed, 0 skipped, 0 warnings)
    - commit: c6589b6
    - review: clean (0 findings)
  timestamp: 2026-09-01T21:42:38.287525+00:00
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
position_column: done
position_ordinal: '8580'
title: 'Instructions: compiled-in floor, wholesale replacement, AGENTS.md assembly'
---
## What
Plan.md §3. Create `Sources/FoundationModelsACPAgent/Instructions/`:

- `BuiltinInstructions.swift` — the compiled-in system prompt floor, which is the guaranteed layer 1. Write a real default coding prompt, not a placeholder sentence.

- `InstructionsAssembler.swift` — per-session assembly:
  1. `Instructions.md` through `stack.content("Instructions.md")`. The nearest layer wins, and it **replaces wholesale**. A `nil` gives the builtin. Trust follows the source: the builtin renders trusted, and any file from disk renders untrusted (§3.1). Render through Extras' `TemplateEngine` with the stack so `{% include %}` resolves `_partials/` through the same layering.
  2. **Preloaded skill bodies.** Call `registry.preloadedBodies()` on the session's `SkillsRegistry` and append the result. It returns ONE already-rendered `String`, joined with blank lines — not raw text and not a list, so do not render it again and do not iterate it. It holds the bodies of skills whose front matter says `preload: true`. **Refresh it when the skills registry reloads**, because a skill edited on disk must change the next turn's instructions.
  3. User-level `AGENTS.md` through `stack.content("AGENTS.md")`.
  4. Project-level documents through Extras' `AgentsMd.documents(from: cwd)` — from the repo root down to cwd, the first of `AGENTS.md`, `AGENT.md` or `CLAUDE.md` per directory, outermost first (§3.2).

  Assembly order: base prompt → preloaded skill bodies → user AGENTS.md → project documents, root to cwd. Divide each file with a header carrying its absolute path. Render each AGENTS document untrusted before assembly. A missing file is absent. A present but unreadable file gives a logged warning, not an error.

- Assemble once at session creation. The result feeds `makeSession(instructions:)` in the session/new task.

**Note on trust.** `DotfolderStack.Layer` carries only `source` and `root`. It has NO trust tag. Trust is a `TemplateEngine` concept, and the source-to-trust mapping is a private helper inside Extras' `LayeredYAMLDocument`. So derive trust yourself from `Layer.source`, with `.defaults` trusted and everything else untrusted, and keep that derivation in one place.

- Discoverability obligation (§3.1): the README, and the DocC page if one exists, shows the builtin instructions text **verbatim**, sourced so it cannot drift. Assert the README section against `BuiltinInstructions` in a test.

- [x] Builtin floor text
- [x] Wholesale replacement and trust-from-source rendering
- [x] Partials resolve through the stack
- [x] Preloaded skill bodies folded in at the right position, and refreshed on reload
- [x] AGENTS.md walk and assembly order with path headers
- [x] README shows the builtin text verbatim

## Acceptance Criteria
- [x] With no files, the assembled text is exactly the rendered builtin
- [x] A project-layer `Instructions.md` fully replaces the builtin, with no merge
- [x] A project can replace one `_partials/` file and keep the builtin prompt
- [x] A skill marked `preload: true` has its rendered body in the assembled instructions; a skill without the flag does not
- [x] Editing that skill on disk changes the next assembly, which proves the reload refresh
- [x] Nested repo directories produce root-to-cwd AGENTS ordering; `CLAUDE.md` is honored as an alias; the nearest file appears last
- [x] Every included file's absolute path appears as a divider header
- [x] A test asserts README.md contains the builtin instructions text verbatim

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift` — temp-dir layer fixtures for each criterion, including the unreadable-file warning case and a temp skills directory for the preload cases
- [x] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — README contains `BuiltinInstructions` verbatim
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.