---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ywj6gpa4spgtx7pvsz11ha
  text: |-
    ### Research — what is already there

    Picked the card up and moved it to `doing`. The two writers the card
    speaks about are both on disk already, so this card adds no third one:

    - `Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift`
      is the generator. `documentText(for:annotation:)` emits the commented
      block YAML. `/config export` calls it
      (`BuiltinCommands.exportConfiguration`), and `config show` calls it.
      `config init` will call the same function with
      `AgentConfiguration()`.
    - `Sources/acp-agent/LayerFileWriter.swift` is the file writer. Its doc
      comment already says it is "the one writer `instructions eject` and
      `config init` share". It holds the `--force` guard, the
      `LayerFileExistsError` that names the flag, and `LayerSelection` with
      the `--user`/`--project` flags. `config init` calls it with
      `ConfigurationLoader.configFileName`.

    So `config init` is: build the stack, generate the text, hand it to
    `LayerFileWriter`, print the path. No new type.

    ### The layer-word mapping

    `/config export` takes `home|project`
    (`BuiltinCommands.configUsage`), and `config init` takes
    `--user|--project`. `BuiltinCommands.ExportLayer.home` writes
    `<userLayerRoot>/config.yaml`; `LayerSelection.user` maps to
    `DotfolderStack.Source.user`, whose layer root is the same directory.
    `ExportLayer` is internal to the library, so CLI production code cannot
    name it. The plan is to state the mapping as a named constant in
    `LayerSelection` and to quote that constant in the `--user` help text,
    so the mapping is live code and the person reading `--help` gets the
    answer too.

    ### `config edit`

    The `$EDITOR` value is a process fact, and every subcommand already
    takes its process facts through an injected `environment` dictionary
    (`report(environment:)`, `AgentComposition.modelSource(environment:)`).
    So `config edit` reads `EDITOR` from that same injected dictionary, and
    a test passes a small shell script that writes the file and exits. No
    test opens a real editor and none can hang.

    ### Baseline

    `swift test` before any change: 457 tests, 47 suites, one known issue at
    `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`.
  timestamp: 2026-09-07T21:32:06.550524+00:00
- actor: claude-code
  id: 01m1yxtfvyqmw8db2p8t581z24
  text: |-
    ### What landed

    **`config init`** — `AcpAgentCommand.Config.Init` in
    `Sources/acp-agent/ConfigCommand.swift`. It takes `--cwd`, the
    `LayerSelection` flags (`--user`/`--project`, project by default) and
    `--force`. Its body is three lines: build the stack, call
    `Config.writeDefaultConfiguration(into:of:overwrites:)`, put the path
    on stdout.

    **One writer, and it is the one that was already there.**
    `Config.writeDefaultConfiguration` is the shared body: it calls
    `ConfigurationYAML.documentText(for: AgentConfiguration())` — the
    generator `/config export` and `config show` already write through —
    and hands the text to `LayerFileWriter.write`, the writer
    `instructions eject` already writes through. The `--force` guard and
    the `LayerFileExistsError` that names the flag are therefore one guard
    for both commands. No new type, and no `ConfigurationWriter.swift`.

    **`config edit`** — `AcpAgentCommand.Config.Edit`. `plan(environment:)`
    resolves the editor first, then `stack.nearest("config.yaml")`. With no
    file in any layer it runs the same `writeDefaultConfiguration` body
    into the project layer and puts the notice on stderr. `run()` writes
    the notice, then opens the editor.

    **`Sources/acp-agent/EditorLauncher.swift`** — new. It reads `EDITOR`
    out of an injected environment dictionary, and runs the command through
    `/usr/bin/env` with the file path as the last argument, argv only and
    no shell. `EditorNotNamedError` names the variable;
    `EditorFailedError` names the command and the status. Both exit 1
    through the existing `AcpAgentCommand.exitOutcome(for:)` path.

    ### The layer-word mapping

    `LayerSelection.userLayerExportWord = "home"` is the one place that
    says `--user` and `/config export home` are one layer. The `--user`
    help text quotes it, so `acp-agent config init --help` now reads:
    "Write into the user layer, $XDG_CONFIG_HOME/acp-agent/. The /config
    export slash command spells this same layer home." The byte-identical
    test spells its `/config` arguments from the same constant.

    ### One change to the shared generator, and why

    The card asks for every key of the schema in the written file. The
    `Codable` synthesis writes an optional property with `encodeIfPresent`,
    so `profile.name`, `compaction.hardCeiling` and
    `compaction.toolOutputLimit` never reached the document at all — a
    person could not see or edit them.

    `ConfigurationYAML.completed(_:forSection:)` now fills a checked
    section's missing schema keys with `null` before the emit. It is one
    change in the one generator, and all four callers get it: `/config`,
    `/config export`, `config show` and `config init`. The round trip stays
    exact, because `decodeIfPresent` reads an explicit `null` as the same
    absence — `ConfigShowTests.jsonDecodesToTheSameValuesAsTheYAML` and
    `BuiltinCommandsTests.configExportProjectRoundTripsThroughTheLoader`
    both still pass, and both reload the emitted text through the loader.

    This is a change to a user-facing output, and it is deliberate: it is
    what "every key of the schema appears in the generated file" means.

    ### How a test drives the editor

    No test opens an interactive editor, and no test can hang.
    `ConfigEditTests` injects `EDITOR` into the same environment dictionary
    every subcommand already takes its process facts from. Three shapes:

    - `editor: nil` and `editor: "   "` prove the refusal, and prove no
      file was written.
    - `failingEditorCommand = "/usr/bin/false"` for the cases that only
      need a valid command; it ends at once and changes nothing.
    - `makeEditorCommand(in:)` writes a two-line `/bin/sh` script into the
      fixture workspace, `chmod 0755`, whose body is
      `printf '%s' '<mark>' > "$1"`. The case runs
      `EditorLauncher.open(plan.file, with: plan.editorCommand)` for real
      and then reads the mark back out of the file. That is what proves the
      launcher handed the chosen path to the editor.

    No `Task.sleep` anywhere: `Process.waitUntilExit()` is a wait for a
    fact.

    ### Verified by hand as well as by test

    Ran the built binary against a throwaway tree: `config init` printed
    the path and exited 0; a second `config init` exited 1 with
    "already exists; pass --force to overwrite it"; `config edit` with no
    `EDITOR` exited 1 with "EDITOR is not set; ..."; `config edit` with
    `EDITOR=/bin/cat` in an empty tree wrote the file, put the notice on
    stderr and nothing of its own on stdout. The written file carries all
    six sections, each under its comment, and now carries `name: null`,
    `hardCeiling: null` and `toolOutputLimit: null` too.
  timestamp: 2026-09-07T21:54:06.846818+00:00
- actor: claude-code
  id: 01m1yxv4kt0xfn7447w6g6q747
  text: |-
    ### implement — changed

    - evidence: 7 files.
      New: `Sources/acp-agent/EditorLauncher.swift`,
      `Tests/FoundationModelsACPAgentTests/ConfigInitTests.swift`,
      `Tests/FoundationModelsACPAgentTests/ConfigEditTests.swift`.
      Changed: `Sources/acp-agent/ConfigCommand.swift`,
      `Sources/acp-agent/LayerFileWriter.swift`,
      `Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift`,
      `Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift`.
    - editor in a test: `$EDITOR` is injected through the environment
      dictionary the subcommand already takes. One case runs a two-line
      `/bin/sh` script (mode 0755) that writes a mark into `$1` and ends;
      the case reads the mark back, which proves the launcher passed the
      path. Other cases pass `/usr/bin/false`, or no variable at all. No
      test opens an interactive editor and no test can wait for a person.
    - `swift build`: clean, no source warning. The build-system line
      `missing creator for mutated node` for the mlx bundle is not a source
      warning.
    - `swift test` three times in sequence: 474 tests in 49 suites passed,
      each run with the one known issue at
      `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`
      (`orderedSubsequenceAssertionChecksOrderWithGaps`). Baseline was 457
      in 47; this card adds 17 tests in 2 suites.
    - next: `/review`.
  timestamp: 2026-09-07T21:54:28.090547+00:00
- actor: claude-code
  id: 01m1yybx17q2cp9ap5fjv1t6ps
  text: |-
    ### review — findings
    - evidence: 3 findings — Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift:165, Sources/acp-agent/ConfigCommand.swift:195, Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift:71
    - scope: review sha HEAD~1..HEAD (commit e1e85e5)
    - next: correct the three findings. Remove the cause from the full file, not only the line. Then do the review again.
  timestamp: 2026-09-07T22:03:37.383012+00:00
- actor: claude-code
  id: 01m1yyccp4p0f5et3jvs6ghrmz
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files
    - test: green — swift test three times, 474 tests in 49 suites, one known issue
    - commit: e1e85e5
    - review: findings — Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift:165 (swift/fluent-usage), Sources/acp-agent/ConfigCommand.swift:195 (duplication/duplication), Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift:71 (reuse/reuse)
  timestamp: 2026-09-07T22:03:53.412942+00:00
- actor: claude-code
  id: 01m1yyr7c6ktm8tr5qpfehm8m3
  text: |
    ### The three findings, and the cause of each removed from the whole file

    **1. `swift/fluent-usage` in `ConfigurationYAML.swift`.** The rule says
    to omit the first argument label only for a value-preserving
    conversion, and to label it in every other case. The cited function is
    now `completed(value:forSection:)`. Three more functions in the same
    file had the same cause, because each one makes a new value from its
    input and does not only convert the type of it:

    - `annotated(_ line:with:)` becomes `annotated(line:with:)`. It adds
      the layer comment to the line.
    - `sequenceItemLines(_ value:indent:)` becomes
      `sequenceItemLines(of:indent:)`, which also matches its two siblings
      `entryLines(key:value:keyPath:indent:)` and
      `childLines(of:keyPath:indent:)`.
    - `indentation(_ level:)` becomes `indentation(atLevel:)`. The spaces
      are made from the level; they are not the level in another type.

    `scalarText(_:)`, `numberText(_:)` and `quoted(_:)` keep the unlabelled
    first parameter. Each one gives the text of the value it receives, so
    each is a value-preserving conversion, which the rule permits.

    **2. `duplication/duplication` in `ConfigCommand.swift`.** The three
    lines that compose the loader and take its stack stood at three places,
    not two: `Init.report()` and `Edit.plan()`, which the finding names,
    and `Path.report()` as well. All three now call one new private helper,
    `Config.makeStack(for:environment:)`. `Show.report()` composes the same
    loader but reads it with `load()`, because it wants the merged values,
    and its doc comment on the helper says so.

    **3. `reuse/reuse` in `ConfigCommandFixture.swift`.**
    `ConfigCommandFixture.text(at:)` is removed. Its six callers in
    `ConfigInitTests` and `ConfigEditTests` now call `textOnDisk(at:)` from
    `AssertionHelpers`, and each of the two suites imports
    `FoundationModelsACPAgentTestSupport`. No other helper of the fixture
    repeats a helper of `AssertionHelpers`: `configURL(in:)`,
    `writeProjectConfig(_:)`, `writeUserConfig(_:)` and
    `writeProjectCompactionTrigger(_:)` each say something the shared file
    does not.

    ### What was NOT changed, and why

    `padded(_ text:to width:)` in `ConfigCommand.swift` has an unlabelled
    first parameter too, but the fluent-usage finding names
    `ConfigurationYAML.swift`, and that function belongs to the earlier
    `config path` card. It is out of the scope of these three findings.

    No behavior changed. Each edit is a rename of a label, a move of three
    lines into one helper, or a change of a test to the shared helper.
  timestamp: 2026-09-07T22:10:21.190098+00:00
- actor: claude-code
  id: 01m1yyrdm4tsgwppcnfz5a3e84
  text: |
    ### implement — changed
    - evidence: 5 files —
      `Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift`,
      `Sources/acp-agent/ConfigCommand.swift`,
      `Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift`,
      `Tests/FoundationModelsACPAgentTests/ConfigInitTests.swift`,
      `Tests/FoundationModelsACPAgentTests/ConfigEditTests.swift`.
    - `swift build`: complete, no source warning. The build-system line
      `missing creator for mutated node` for the mlx bundle is not a source
      warning.
    - `swift test` twice: 474 tests in 49 suites passed, each run with the
      one known issue at
      `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift`
      (`orderedSubsequenceAssertionChecksOrderWithGaps`). That is the
      baseline, unchanged.
    - All three review findings are now `- [x]` on the card.
    - next: `/review`.
  timestamp: 2026-09-07T22:10:27.588099+00:00
depends_on:
- 01M1MNYFW81216M57PS9NDZKBE
position_column: doing
position_ordinal: '80'
title: config init and config edit, sharing one writer with /config export
---
## What

cli-plan.md §5.11. `config show` reads; these two write.

**There is already a generator — do not write a second one.**
`Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift`
emits the commented block YAML that `/config export` writes, and its own
doc comment records that the text round-trips through
`ConfigurationLoader`. This card **calls that type**; it does not
extract a new `ConfigurationWriter`.

**`config init`** writes a `config.yaml` with every key at its default,
each under a comment.

- `--user` writes the user layer, `--project` the project layer.
  `--project` is the default.
- It refuses to overwrite an existing file, exits 1, and names
  `--force`. `--force` overwrites.
- It prints the path it wrote, to stdout.

**The layer names differ between the two front doors, and the mapping
must be stated.** `/config export` takes `home|project`
(`BuiltinCommands.swift`: `configUsage = "Usage: /config export
home|project"`), while `config init` takes `--user|--project`. Map
`--user` ↔ `home` in one place, and say so in the code, so a reader is
not left guessing whether they are two layers or one.

**`config edit`** opens the nearest `config.yaml` in `$EDITOR`. With no
file in any layer it runs the `config init` path first and says so on
stderr. With no `$EDITOR` it exits 1 and names the variable.

- [x] `config init` over the existing `ConfigurationYAML`
- [x] `--user`, `--project`, `--force`, and the `home` mapping
- [x] `config edit`, with the missing-file and missing-`$EDITOR` paths
- [x] No new generator type

## Acceptance Criteria

- [x] `config init` writes a file that `ConfigurationLoader` reads back
      to exactly `AgentConfiguration()`.
- [x] Every top-level section and every key of the schema appears in the
      generated file.
- [x] A second `config init` without `--force` exits 1 and changes no
      file.
- [x] `config edit` with no `$EDITOR` exits 1 and names the variable.
- [x] `config init --user` and `/config export home` write
      byte-identical files to the same path.
- [x] No file named `ConfigurationWriter.swift` is added.

## Tests

- [x] `ConfigInitTests`: write into a temporary stack, load it back, and
      assert equality with `AgentConfiguration()`.
- [x] A test walks `AgentConfiguration.sectionSchemas` and asserts each
      known key appears in the generated text. A new key with no comment
      fails the test.
- [x] The refuse-to-overwrite path, and the `--force` path.
- [x] A test asserts `config init --user` and `/config export home`
      produce byte-identical output.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-07 16:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACPAgent/Configuration/ConfigurationYAML.swift:165` `swift/fluent-usage` — First parameter of non-value-preserving function should be labeled. The `completed` function augments input by inserting null values for missing schema keys, transforming rather than purely converting the value type. Change `private static func completed(_ value: Any, forSection section: String)` to `private static func completed(value: Any, forSection section: String)` to label the first parameter.
- [x] `Sources/acp-agent/ConfigCommand.swift:195` `duplication/duplication` — The ConfigurationLoader stack initialization is duplicated identically at lines 195–197 and lines 406–408, creating a maintenance risk if one copy is updated without updating the other. Extract the duplicated lines to a shared private helper method in the Config class: `private func makeStack(environment: [String: String]) throws -> DotfolderStack { return try AgentComposition.makeConfigurationLoader(workingDirectory: workingDirectoryOptions.directoryURL, environment: environment).stack }`, then call it from both Init.report() and Edit.plan().
- [x] `Tests/FoundationModelsACPAgentTests/Support/ConfigCommandFixture.swift:71` `reuse/reuse` — The `text(at:)` function reimplements the same capability as `textOnDisk()` in AssertionHelpers—both read UTF-8 text from a file URL and throw on error. Should call the existing shared test helper instead of duplicating it. Import and call `textOnDisk()` from AssertionHelpers instead of reimplementing.