---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1vpg2p4mmxep28ja3e0p5nd
  text: |-
    ### implement — research and decisions

    Picked up. What the research found, and the decisions the code follows:

    - `LayeredYAMLDocument.sourcesByKeyPath` is private, but `source(of: [String])` is public. The loader walks `document.root` after the merge and asks `source(of:)` for each key path, so no change to Extras is necessary. The map is keyed by the dotted key path (`recording.level`). Only key paths a layer set are in the map; a key with no entry is builtin.
    - The merge records a section key (`recording`) with the layer that first introduced it, and each child key the layer set. A default child under a set section (`compaction.target` when only `compaction.trigger` is in the file) has NO entry, so a report must not walk up to a parent to find a source: that would report `project` for a builtin value. Keys inside a sequence item (an `mcp` server body) also have no entry, because a sequence replaces wholesale; the sequence key carries the annotation, and the item keys carry none.
    - `ConfigurationYAML` (internal, `/config` and `/config export`) already renders the merged `AgentConfiguration` as block YAML from its `Codable` encoding. `config show` reuses it. The emitter becomes key-path aware so `--source` can append `# <layer>` to each key line, and the type becomes public so the CLI target reaches it. The `/config` builtin output does not change.
    - `DotfolderStack.Source` has no `builtin` case. A new `ConfigurationLayerName` (`builtin`, `defaults`, `user`, `project`) maps `nil` to `builtin` in one place, and both `config show --source` and `config path` name layers through it. This package passes no defaults directory, so `defaults` appears only under an `ACP-AGENT_DEFAULTS_DIR` override.
    - `--json --source`: JSON has no comments, so the document is `{"configuration": <tree>, "sources": {<dotted key>: <layer>}}` with every key of the tree in `sources`. Without `--source` the JSON is the tree alone. The help text says so.
    - `--cwd` moves into one `WorkingDirectoryOptions` option group that `run`, `config show` and `config path` share, so the help text and the default (the process working directory) exist once. `Run.workingDirectory` stays as a computed property, so its `validate()` and the parse tests do not change.
    - `config path` prints one row per stack layer after the builtin row, so a defaults layer under the override would show honestly. The mark is `exists` when the layer directory is a directory on disk, `missing` otherwise. No `TerminalRenderer`, no ANSI.
    - The `IntegrationTests` package holds `CLIProcessTests`, which spawns the built binary and injects `XDG_CONFIG_HOME`. Two process cases prove exit 0 and stdout for both subcommands across the real boundary.
    - No formatter config file (`.swift-format`) is in the repository, so no format step runs before the commit.
    - `swift package reset` could not remove `.build/index-build` (an indexer holds it); the rest of `.build` was removed and the package resolved again.
  timestamp: 2026-09-06T15:48:22.340669+00:00
- actor: claude-code
  id: 01m1vq91bbektdhrb1w6gje9mn
  text: |-
    ### implement — the work, in TDD order

    RED first: `ConfigurationLoaderTests` (2 new cases), `ConfigShowTests` (11 cases), `ConfigPathTests` (4 cases), the shared `ConfigCommandFixture`, and 2 process cases in `CLIProcessTests`. `swift build --build-tests` failed on the missing API only: `LoadedConfiguration.sources`, `CommandReport`, `Show.report(environment:)`, `Path.report(environment:)`, `annotatesSource`, `asJSON`, `workingDirectoryOptions`.

    GREEN:
    - `ConfigurationLoader.swift`: `LoadedConfiguration.sources: [String: DotfolderStack.Source]`, keyed by dotted key path, and `keyPathSeparator`. `load()` walks `document.root` and copies `document.source(of:)` out for each key path before the document goes out of scope. The memberwise init is internal, so the two existing callers of `configuration`/`warnings` compile unchanged.
    - `ConfigurationLayerName.swift` (new, public): `builtin`, `defaults`, `user`, `project`, with `init(_ source: DotfolderStack.Source?)` that maps `nil` to `builtin` — the one place the card asks for.
    - `ConfigurationYAML.swift`: now public. The emitter returns structured `Line` values (text plus the dotted key path, or `nil` for a comment, a sequence item, and a key inside a sequence item), so `documentText(for:annotation:)` appends `  # <layer>` under `KeyAnnotation.sources(...)`, and `keyPaths(of:)` lists every key of the tree from the same walk. The accumulator loops became `flatMap` chains. The `/config` builtin output is unchanged (`BuiltinCommandsTests` pass).
    - `Sources/acp-agent/WorkingDirectoryOptions.swift` (new): the shared `--cwd` option group; `Run` uses it and keeps `workingDirectory` as a computed property, so `validate()` and `CLIParsingTests` did not change.
    - `Sources/acp-agent/CommandReport.swift` (new): the stdout text and the stderr lines as a value, written in one place.
    - `ConfigCommand.swift`: `Show` (YAML, `--source`, `--json`, `--json --source` as `{"configuration", "sources"}`) and `Path` (the builtin row, then one aligned row per stack layer with `exists`/`missing`, from `FileManager.fileExists(atPath:isDirectory:)`). Both build their `CommandReport` from `report(environment:)`, and `run()` writes it.
    - `AgentComposition.makeConfigurationLoader(workingDirectory:environment:)`: the one loader construction `compose`, `Show` and `Path` share.
    - `cli-plan.md` §5.2: the sentence that listed `config path` among the renderer's callers now says it does not call the renderer, as the card decided.

    Checks: `swift build --build-tests` clean; `swift test --filter 'ConfigurationLoaderTests|ConfigShowTests|ConfigPathTests|CLIParsingTests|AgentCompositionTests|BuiltinCommandsTests'`: 60 tests in 6 suites passed. The built binary: `config path --cwd <dir>` exit 0, three aligned rows, 0 bytes on stderr; `config show --source --cwd <dir>` with a project file that sets `recording.level` and an unknown `permissions` section: `recording:  # project`, `level: "off"  # project`, every other key `# builtin`, and the one warning line on stderr; `config show --json --source` holds `configuration` and `sources`.

    A note for the next agent: `swift package resolve` failed twice with "swift-distributed-tracing couldn't be removed". The reset had deleted that checkout's `.git`, and the `sourcekit-lsp` this session's `sah serve` runs kept recreating a nested `Samples/Dinner/.build/index-build` inside it, so SwiftPM could not remove the directory to re-clone. The fix was to move the directory aside (`mv` is atomic and works with open files) and resolve again; the two moved directories are under `.build/indexer-held-*`, which git ignores.

    ### implement — changed
    - evidence: 14 files — Sources/FoundationModelsACPAgent/Configuration/{ConfigurationLoader,ConfigurationLayerName,ConfigurationYAML}.swift, Sources/acp-agent/{ConfigCommand,RunCommand,AgentComposition,WorkingDirectoryOptions,CommandReport}.swift, Tests/FoundationModelsACPAgentTests/{ConfigurationLoaderTests,ConfigShowTests,ConfigPathTests}.swift, Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/CLIProcessTests.swift, cli-plan.md
    - next: test, then commit, then review
  timestamp: 2026-09-06T16:02:00.172+00:00
- actor: claude-code
  id: 01m1vxadyyzqasn7mq7fjb90j6
  text: |-
    ### test — green for this card, with one recorded exception
    - evidence: `swift test` (root): 384 tests in 38 suites passed, 0 failed, 1 pre-existing known issue (`HarnessSmokeTests.swift:239`, a `withKnownIssue` block); the only build warning is the build system's `warning: missing creator for mutated node: ('.../.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`, not a source warning. `swift test --package-path IntegrationTests`: 28 tests in 7 suites, 1 failed; `PythonCLIDatasetTests`, `PythonCLISubjectTests`, `EvaluatorHonestyTests`, `CLIProcessTests` (6 cases, the two new `config show`/`config path` process cases included), `StdioContractTests`, `ClientServerTests` passed. The only failure is the known live-model defect ^pez780d, outside this card, exact text: `Test "The composed agent builds Python CLIs end to end over ACP" recorded an issue at PythonCLIEvaluation.swift:335:13: Expectation failed: mean >= pythonCLIEvalMeanFloor` (4 times) / `Test "The composed agent builds Python CLIs end to end over ACP" failed after 6224.515 seconds with 4 issues.` / `Suite PythonCLIEvaluationTests failed after 6224.515 seconds with 4 issues.` / `Test run with 28 tests in 7 suites failed after 6224.515 seconds with 4 issues.` Treated as not red for this card, as the loop instruction says.
    - a note: the process cases finished at 98 s, but the log showed them only later, because the test host buffers its output to the file. A `sample` of the host showed the eval's synchronous MLX generation on the cooperative threads, which is why nothing else is scheduled while it runs.
    - next: commit, then review
  timestamp: 2026-09-06T17:47:37.310669+00:00
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: doing
position_ordinal: '80'
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

- [x] Vend per-key source data from `ConfigurationLoader`
- [x] `config show`, with `--source` and `--json`
- [x] `config path`, with the exists mark, plain text on stdout
- [x] Both honor `--cwd`; warnings to stderr

## Acceptance Criteria

- [x] `LoadedConfiguration` exposes a per-key source map, and the
      existing `configuration`/`warnings` callers still compile.
- [x] With no file in any layer, every key reports `builtin`.
- [x] With a project `config.yaml` that sets one key, that key reports
      `project` and the others `builtin`.
- [x] `config show --json` parses as JSON and holds the same values.
- [x] `config path` names three layers with correct exists marks, and
      its output holds no ANSI escape.
- [x] Both exit 0 and write their report to stdout.

## Tests

- [x] `ConfigurationLoaderTests`: a two-layer fixture asserts the
      per-key source map — the overridden key maps to `project`, an
      untouched key maps to `nil`.
- [x] `ConfigShowTests`: the merged values and the per-key annotation,
      against the same fixture.
- [x] The `--json` output decodes and equals the YAML output's values.
- [x] `ConfigPathTests`: with only the project layer present, the marks
      are right, and the output holds no `ESC[`.
- [x] A test asserts a configuration warning goes to stderr and never to
      stdout.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.