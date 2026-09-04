---
assignees:
- claude-code
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: todo
position_ordinal: 8a80
title: 'config show and config path: make the invisible configuration visible'
---
## What

cli-plan.md §5.11. Nothing is on disk after an install, so the
configuration is invisible today. These two commands show it.

**A loader change comes first, and this card owns it.**
`ConfigurationLoader.load()` builds a `LayeredYAMLDocument`, reads it,
and lets it go out of scope. `LoadedConfiguration` carries only
`configuration` and `warnings`, and the document's
`sourcesByKeyPath` store is `private`. So the per-key provenance that
`--source` needs is **thrown away inside the loader**, and no other card
recovers it. Extend `LoadedConfiguration` (or `ConfigurationLoader`)
with a per-key source accessor — a `[String: DotfolderStack.Source]`
keyed by dotted key path is enough — and keep the existing API working.

`DotfolderStack.Source` has no `builtin` case, so a key that no layer
set returns `nil`. Map `nil` to `builtin` in the report, and say so in
the code.

**`config show`** prints the merged configuration as YAML to stdout.
`--source` annotates each key with the layer that set it: `builtin`,
`user` or `project`. `--json` prints the same tree as JSON. It honors
`--cwd`. Configuration warnings go to stderr, never to stdout.

**`config path`** prints each layer path, one per line, with a mark for
the ones that exist:

```
builtin  (in code, no file)
user     /Users/x/.config/acp-agent/     exists
project  /Users/x/repo/.acp-agent/       missing
```

**`config path` writes plain text to stdout, and does NOT use
`TerminalRenderer`.** cli-plan §5.2 lists it among the renderer's
callers and §5.6 puts it on stdout; the two cannot both hold, because
the renderer is stderr-only. §5.6 wins: this is a report, and a report
is data. This card supersedes that line of §5.2, so it needs no
dependency on the Noora card.

- [ ] Vend per-key source data from `ConfigurationLoader`
- [ ] `config show`, with `--source` and `--json`
- [ ] `config path`, with the exists mark, plain text on stdout
- [ ] Both honor `--cwd`; warnings to stderr

## Acceptance Criteria

- [ ] `LoadedConfiguration` exposes a per-key source map, and the
      existing `configuration`/`warnings` callers still compile.
- [ ] With no file in any layer, every key reports `builtin`.
- [ ] With a project `config.yaml` that sets one key, that key reports
      `project` and the others `builtin`.
- [ ] `config show --json` parses as JSON and holds the same values.
- [ ] `config path` names three layers with correct exists marks, and
      its output holds no ANSI escape.
- [ ] Both exit 0 and write their report to stdout.

## Tests

- [ ] `ConfigurationLoaderTests`: a two-layer fixture asserts the
      per-key source map — the overridden key maps to `project`, an
      untouched key maps to `nil`.
- [ ] `ConfigShowTests`: the merged values and the per-key annotation,
      against the same fixture.
- [ ] The `--json` output decodes and equals the YAML output's values.
- [ ] `ConfigPathTests`: with only the project layer present, the marks
      are right, and the output holds no `ESC[`.
- [ ] A test asserts a configuration warning goes to stderr and never to
      stdout.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.