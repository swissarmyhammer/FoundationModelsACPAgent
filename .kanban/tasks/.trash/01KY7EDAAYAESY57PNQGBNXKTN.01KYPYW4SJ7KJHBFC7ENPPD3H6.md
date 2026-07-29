---
comments:
- actor: claude-code
  id: 01kypyd9gpwpxkb2bctfhmh5s2
  text: |-
    **2026-07-29 — `Instructions.md` uses Extras for both stacking and templating. Do not hand-roll the layer walk.** Plan §6.0 now spells out the composition, and the Extras API matches this task's rules exactly rather than approximately:

    ```swift
    // Stacking: content(_:) returns the NEAREST layer's file, whole — precisely
    // "nearest wins, wholesale replace". Nil means no layer overrode the floor.
    let source = stack.content("Instructions.md")

    // Trust is derived from provenance, not configured.
    let text  = source ?? Self.builtinInstructions
    let trust: TemplateEngine.Trust = (source == nil) ? .trusted : .untrusted

    // Templating: the engine takes the same stack, so {% include %} resolves
    // _partials/ through the same layering.
    let rendered = try engine.render(text, context: context, trust: trust)
    ```

    Three points that change how this is built:

    - **No layer-walking of our own.** `DotfolderStack.content(_:)` *is* the resolution rule — this task names precedence rather than implementing it. (`nearest(_:)` / `locate(_:)` exist if a diagnostic needs to report *which* file won.)
    - **Trust is derived, not a flag.** `content(_:)` returning `nil` means nothing on disk overrode the compiled-in floor, so the text is ours and renders **trusted**; anything it returns came from a user or project file and renders **untrusted**. There is no third case and nothing to keep in sync — layers 2 and 3 are both untrusted, so they never need distinguishing.
    - **Partials stack too, and that is the real win.** `TemplateEngine(partials:)` takes the same stack, so an `{% include "role" %}` in a user-level `Instructions.md` resolves `_partials/` with nearest-layer-wins. **A project can override one partial without replacing the whole prompt** — recovering the granularity that wholesale replacement otherwise costs, without inventing a merge rule for prose. Worth a test.

    The untrusted render is §4's existing one: validated, side-effect-free, no filesystem or exec reach, metered on include-depth, loop-iteration, and output-size budgets. A hostile `Instructions.md` in a cloned repo is bounded by the same limits as any other untrusted document.

    Tests to add:
    - [ ] No file on disk → compiled-in text, rendered **trusted**.
    - [ ] User-layer file → that text, rendered **untrusted**.
    - [ ] Project-layer file → wins over user layer, still untrusted.
    - [ ] `{% include %}` of a partial present in both layers resolves to the project's copy while the base prompt still comes from the user layer.
    - [ ] An untrusted `Instructions.md` attempting filesystem or exec reach is refused, and a runaway include depth is capped.
  timestamp: 2026-07-29T12:43:22.006127+00:00
depends_on:
- 01KY7ECSJGTV23JVX3D4AXZGQM
position_column: todo
position_ordinal: '8280'
title: 'Instructions assembly: stacked Instructions.md + AGENTS.md'
---
Plan **§6.0 + §6.1**. Per session, keyed to its cwd.

**Revised 2026-07-28: the `instructions.replace` / `instructions.append` config keys are DELETED.** A system prompt is prose, and packing prose into YAML is unnatural to write, awkward to diff, and cut off from the templating and `{% include %}` machinery every other markdown document here gets. The base prompt is now a stacked markdown file, and addition is AGENTS.md's job.

## The base prompt: `Instructions.md` (§6.0)

Resolved through the same layering as everything else — **nearest layer wins, wholesale**:

| Layer | Location |
|---|---|
| 1 | **compiled in** — the guaranteed floor; never edited, only shadowed |
| 2 | `~/.config/<name>/Instructions.md` |
| 3 | `<project>/.<name>/Instructions.md` |

**Layer 1 is compiled in, and that is a deliberate exception to §4's "real files, never embedded" rule.** Every other layer-1 artifact degrades safely to nothing — absent config means defaults, an absent `commands/` means no commands. The system prompt is the one artifact where *nothing* is not a valid value: an agent whose defaults directory was never materialized, or was emptied by a bad install, or is pointed at a broken `<NAME>_DEFAULTS_DIR`, must still have a prompt, or the failure mode is a silently lobotomized agent instead of an error. The original lesson still holds because the compiled-in copy is a **floor, not an edit surface** — you shadow it, never edit it, so changing the prompt still never requires a build.

Do **not** also materialize it into the defaults directory. That was considered and rejected: two sources of the same default drift, and it creates ambiguity about which wins.

## Assembly order

`Instructions.md` (nearest layer) → user-level `~/.config/<name>/AGENTS.md` via `DotfolderStack.content` → project-level `AgentsMd.documents(from: cwd)`, outermost-first so nearest-to-cwd lands last. **No trailing config-supplied segment** — the last word belongs to the nearest `AGENTS.md`.

The two lanes stay cleanly separated: **`Instructions.md` replaces, `AGENTS.md` adds.** The old `instructions.append` use case ("prefer swift-testing over XCTest") is exactly what agents.md exists to carry, so nothing is lost by deleting the key — it redirects to the file type built for it.

## Unchanged from before

Each file delimited by a header naming its absolute path (attribution); missing files simply absent; a present-but-unreadable file is a logged warning, not the hard error config files get — this is content, not configuration. Result folds into the `instructions` value handed to `makeSession`; Router never knows. Read once at session creation and pinned for the session's lifetime.

**Templating:** the compiled-in copy renders **trusted**; layer-2 and layer-3 overrides render **untrusted** (§4's one rule, unchanged).

**BLOCKED cross-repo** on Extras task `67w7zj6` (`AgentsMd`), still pending — that is the project-level walk only. The `Instructions.md` stack does not depend on it and can land first.

## Discoverability — the cost of a compiled-in floor

A file you cannot see is a file you cannot fork, so this has to be paid explicitly (§4's published-artifact contract):

- [ ] The builtin text is reproduced verbatim in DocC/README.
- [ ] The CLI can print the fully assembled prompt for a session.
- [ ] The CLI can **eject** the builtin to a layer-2 or layer-3 path as a starting point for editing (`<cli> instructions --eject`).

## Acceptance Criteria

- [ ] With no `Instructions.md` anywhere on disk, the agent still has the compiled-in prompt.
- [ ] A layer-2 file replaces the compiled-in prompt wholesale.
- [ ] A layer-3 file replaces a layer-2 file wholesale.
- [ ] `AGENTS.md` content appends after whichever base won.
- [ ] Every segment carries an absolute-path attribution header (the compiled-in one identifies itself as builtin).
- [ ] No `instructions:` key is read from config; its presence warns as an unknown section.

## Tests

- [ ] Empty stack (no defaults dir, no user file, no project file) → compiled-in prompt, non-empty.
- [ ] Layer 2 present → exactly that text as the base, compiled-in text absent.
- [ ] Layers 2 and 3 both present → layer 3 wins wholesale, no concatenation of the two.
- [ ] Base + user AGENTS.md + two project AGENTS.md files → correct order, nearest-to-cwd last.
- [ ] An unreadable `Instructions.md` logs a warning and falls back to the next layer rather than erroring.
- [ ] A layer-3 override containing template syntax renders untrusted (no filesystem/exec reach) and is metered.
- [ ] Eject writes a file that, when left in place, reproduces the compiled-in prompt byte-for-byte.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.