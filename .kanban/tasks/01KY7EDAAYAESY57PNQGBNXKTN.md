---
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