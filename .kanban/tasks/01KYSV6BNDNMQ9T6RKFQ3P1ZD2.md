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

- `BuiltinInstructions.swift` — the compiled-in system prompt floor (the guaranteed layer 1; write a real default coding prompt, not a placeholder sentence).
- `InstructionsAssembler.swift` — per-session assembly:
  1. `Instructions.md` via `stack.content("Instructions.md")` — nearest layer wins, **wholesale replace**; `nil` → builtin. Trust derives from source: builtin renders trusted, any file from disk renders untrusted (§3.1). Render through Extras' `TemplateEngine` with the stack so `{% include %}` resolves `_partials/` through the same layering.
  2. User-level `AGENTS.md` via `stack.content("AGENTS.md")` (additive, first).
  3. Project-level documents via Extras' `AgentsMd.documents(from: cwd)` — repo root down to cwd, first of `AGENTS.md`/`AGENT.md`/`CLAUDE.md` per directory, outermost first (§3.2).
  - Assembly order: base prompt → user AGENTS.md → project docs (root → cwd). Each file divided by a header carrying its absolute path. Each AGENTS document renders untrusted before assembly. Missing file = absent; present-but-unreadable = logged warning, not an error.
- Assembled once at session creation; the result feeds `makeSession(instructions:)` in the session/new task.
- Discoverability obligation (§3.1 — "the cost of a compiled-in floor"): the README (and DocC page if present) shows the builtin instructions text **verbatim**, sourced so it cannot drift (e.g. the README section is asserted against `BuiltinInstructions` by a test).

- [ ] Builtin floor text
- [ ] Wholesale replacement + trust-from-source rendering
- [ ] Partials resolve through the stack
- [ ] AGENTS.md walk + assembly order with path headers
- [ ] README/DocC shows the builtin text verbatim

## Acceptance Criteria
- [ ] No files → assembled text is exactly the rendered builtin
- [ ] A project-layer `Instructions.md` fully replaces the builtin (no merge)
- [ ] A project can replace a single `_partials/` file while keeping the builtin prompt
- [ ] Nested repo dirs produce root→cwd AGENTS ordering; `CLAUDE.md` honored as alias; nearest file appears last
- [ ] Every included file's absolute path appears as a divider header
- [ ] A test asserts README.md contains the builtin instructions text verbatim

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift` — temp-dir layer fixtures for each acceptance criterion, including an unreadable-file warning case
- [ ] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift` — README contains `BuiltinInstructions` verbatim
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.