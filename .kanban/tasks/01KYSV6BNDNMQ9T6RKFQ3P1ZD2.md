---
assignees:
- claude-code
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
position_column: todo
position_ordinal: '8480'
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

- [ ] Builtin floor text
- [ ] Wholesale replacement and trust-from-source rendering
- [ ] Partials resolve through the stack
- [ ] Preloaded skill bodies folded in at the right position, and refreshed on reload
- [ ] AGENTS.md walk and assembly order with path headers
- [ ] README shows the builtin text verbatim

## Acceptance Criteria
- [ ] With no files, the assembled text is exactly the rendered builtin
- [ ] A project-layer `Instructions.md` fully replaces the builtin, with no merge
- [ ] A project can replace one `_partials/` file and keep the builtin prompt
- [ ] A skill marked `preload: true` has its rendered body in the assembled instructions; a skill without the flag does not
- [ ] Editing that skill on disk changes the next assembly, which proves the reload refresh
- [ ] Nested repo directories produce root-to-cwd AGENTS ordering; `CLAUDE.md` is honored as an alias; the nearest file appears last
- [ ] Every included file's absolute path appears as a divider header
- [ ] A test asserts README.md contains the builtin instructions text verbatim

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift` — temp-dir layer fixtures for each criterion, including the unreadable-file warning case and a temp skills directory for the preload cases
- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — README contains `BuiltinInstructions` verbatim
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.