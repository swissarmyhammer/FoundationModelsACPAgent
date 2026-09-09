---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m226s3scv8wf3bhffvq7wh6e
  text: |-
    ### The three Metal questions — answered from the source

    **1. What is the exact library filename?**

    There are two names, and only one of them is a real artifact.

    - `mlx.metallib` is the name of mlx's **first probe**, not of a shipped
      file. Router's `MetalLibraryTestBootstrap` (in
      `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift`)
      makes a **symlink** with this name beside the running test binary.
      Nothing builds a file with this name.
    - `default.metallib` is the real artifact. mlx-swift builds it into the
      SwiftPM resource bundle `mlx-swift_Cmlx.bundle`, at
      `Contents/Resources/default.metallib`.

    mlx (`mlx/backend/metal/device.cpp`, `load_default_library`) probes, in
    order:

    1. `<binary-dir>/mlx.metallib`
    2. `<binary-dir>/Resources/mlx.metallib`
    3. a SwiftPM resource bundle reached from the main bundle, or from any
       bundle in `Bundle.allBundles` / `Bundle.allFrameworks`
    4. `<binary-dir>/Resources/default.metallib`
    5. `<working-directory>/default.metallib`

    **2. Where must it stand, relative to an installed `acp-agent`?**

    Not beside the binary as a file. The bundle directory
    `mlx-swift_Cmlx.bundle` stands **beside the executable**, and the library
    is inside it. Measured in this working tree:

    ```
    .build/debug/acp-agent
    .build/debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
    ```

    For a plain executable, `Bundle.main` roots at the directory that holds
    the executable, so probe (3) finds the bundle. Probe (1) — the sibling
    `mlx.metallib` file — is never reached, and never needed.

    **3. What produces it there?**

    mlx-swift's own SwiftPM resource bundle. This repository produces
    nothing: it has no `.metal` source, no checked-in `.metallib`, and no
    install step that copies one. SwiftPM puts the bundle beside the built
    executable on its own.

    ### The decision: the Runtime row is dropped

    The card's own condition applies word for word: an installed binary
    finds the library through mlx-swift's resource bundle and never needs a
    sibling file. So the row is dropped.

    The symlink exists only because a `.xctest` binary sits at
    `<Target>.xctest/Contents/MacOS/<Target>`, two directory levels below
    `<Target>.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/...`, so every
    probe misses under a plain `swift test`. That is a **test-layout**
    defect, not an install-layout one. It is Router's to hold, and Router
    already holds it.

    A check written against `<binary-dir>/mlx.metallib` would therefore
    report an error on every correct install. A check written against the
    bundle would only restate what SwiftPM guarantees, and it names no
    configuration key, so it could carry no fix a person can act on.

    **cli-plan.md §5.12, the Runtime row — "The Metal shader library stands
    beside the binary" — is superseded.** The library does not stand beside
    the binary. Its bundle does, and mlx finds it there without help.

    ### The skills stack

    `ToolCatalog.makeSkillsRegistry` builds
    `DotfolderStack(name: ToolCatalog.skillsDotfolderName, workingDirectory:)`
    with `skillsDotfolderName == "skills"`, and hands the stack to
    `SkillsRegistry(stack:watch: true)`. `SkillDiscovery.roots(from:)` is
    `stack.layers.map(\.root)`, so every layer root is read. With no
    defaults directory the stack has two layers: the user layer
    (`$XDG_CONFIG_HOME/skills`, else `~/.config/skills`) and the project
    layer (`<workingDirectory>/.skills`).

    So the check is one row per layer root: not on disk is `.ok` (skills are
    optional), unreadable is an `.error`.
  timestamp: 2026-09-09T04:28:22.188607+00:00
- actor: claude-code
  id: 01m22747c7en7gk7jhrmnc8bqq
  text: |-
    ### What landed

    `RuntimeDoctor`, category `runtime`, registered fifth in
    `AcpAgentCommand.Doctor.components(...)`. It reports one row per layer
    of `DotfolderStack(name: ToolCatalog.skillsDotfolderName, ...)`:

    - not on disk gives `.ok` — skills are optional;
    - unreadable gives an `.error` whose fix is `chmod u+rx <path>, or
      remove it`;
    - readable gives `.ok`.

    With `tools.skills: false` the component reports one `.ok` row that
    names the key and says disabled, and it reads no layer.

    The component takes the environment as an argument, so the test drives
    it over `ConfigCommandFixture` and no test reads the real home
    directory. No test reaches a GPU, a process or the network.

    ### Two shared helpers, so nothing is written twice

    The two previous cards each took a duplication finding, so this card
    extracted before it wrote:

    - `Doctor/ReadableDirectoryState.swift` — the layer read rule
      (`missing` / `unreadable` / `readable`) and the `chmod u+rx` command.
      `ConfigurationDoctor` had that rule and that constant privately;
      it now switches on the shared type, and its behaviour does not
      change. `ConfigurationDoctorTests` passes untouched.
    - `Doctor/DisabledSectionCheck.swift` — the row of a tool section that
      is off. `ToolsDoctor` held it privately for the shell and the mcp
      rows; both now call the shared helper, with the same message.

    `WritableDirectoryCheck` and `ProbeTimeout` were read first and are
    untouched: neither answers a read-only question.

    ### TDD, and what went red

    The tests were written first. `swift build --build-tests` failed with:

    ```
    DoctorRegistryTests.swift:61:17: error: cannot find 'RuntimeDoctor' in scope
    ```

    That is the whole red: the component did not exist. After the three new
    source files and the registration, the four doctor suites went green
    (23 tests), then the whole suite.

    ### One test was dropped on purpose

    An early draft carried a fifth case: a plain file standing at
    `<workspace>/.skills`. It was removed. `FileManager.isReadableFile`
    answers `true` for a readable file, and the message "can be read" is
    then literally true; the stack simply finds no skill there, exactly as
    it finds none in a missing layer. So the honest answer is `.ok`, the
    card asks for three cases, and a fourth row would have forced a fourth
    state into `ReadableDirectoryState` that `ConfigurationDoctor` does not
    share.

    ### Validators run before the review step

    - `swiftlint` with the gate's rule set and thresholds: clean over
      `Doctor/`, `DoctorCommand.swift` and `Tests/.../Doctor/`.
    - `swiftformat --lint` with the 27 idiom rules and the gate's options:
      0 of 20 files require formatting.
    - `periphery scan --retain-public`: no finding on any new symbol.

    ### cli-plan.md

    §5.12's Runtime row is struck through and marked SUPERSEDED, with the
    reason written under the table and the card id cited. The Skills row
    stands, and the text says `RuntimeDoctor` carries it under the
    `runtime` category.
  timestamp: 2026-09-09T04:34:26.311391+00:00
- actor: claude-code
  id: 01m2274dn41nsydbr9cb1k90fq
  text: |-
    ### implement — changed
    - evidence: 9 files. New: Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift, Sources/FoundationModelsACPAgent/Doctor/ReadableDirectoryState.swift, Sources/FoundationModelsACPAgent/Doctor/DisabledSectionCheck.swift, Tests/FoundationModelsACPAgentTests/Doctor/RuntimeDoctorTests.swift. Changed: Sources/FoundationModelsACPAgent/Doctor/ConfigurationDoctor.swift, Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift, Sources/acp-agent/DoctorCommand.swift, Tests/FoundationModelsACPAgentTests/Doctor/DoctorRegistryTests.swift, cli-plan.md. Red first: `cannot find 'RuntimeDoctor' in scope` at DoctorRegistryTests.swift:61:17. Green: `swift test` gives 555 tests in 60 suites, 1 known issue at HarnessSmokeTests.swift:239, zero failures and zero warnings. The baseline was 550 in 59; the new suite adds 5 tests.
    - next: /review
  timestamp: 2026-09-09T04:34:32.740405+00:00
- actor: claude-code
  id: 01m227p3jq0gz3ctg5kbwev1dv
  text: |
    ### review — findings
    - evidence: 1 finding, 1 confirmed, 1 refuted, 7 attempted — `review sha HEAD~1..HEAD`; Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift:118
    - merit check 1, the extraction: behaviour is kept. `ReadableDirectoryState.of(_:)` does `fileExists(atPath:)` and then `isReadableFile(atPath:)`, in that order, as `ConfigurationDoctor.check(of:)` did. `readFix` is the same text `chmod u+rx`, and the messages and the fix line of the configuration layer row are unchanged. `DisabledSectionCheck.check(name:key:category:)` makes the same `.ok` row with the same sentence, and `ToolsDoctor` gives it the same category value. The unedited tests of both components are the guard, and the code agrees with them.
    - merit check 2, the Metal row: the drop is correct. The card set the drop condition, and the source meets it. `default.metallib` is inside the SwiftPM resource bundle `mlx-swift_Cmlx.bundle`, `Bundle.main` of a plain executable roots at the directory of the executable, and nothing in this repository makes the library. A check of a sibling file would fail on every correct install. To strike the plan row and to write the reason under the table is the correct record, because the plan keeps the history of the decision. No finding.
    - family rules: `RuntimeDoctor.runHealthChecks()` does not throw, and the one `.error` row carries a `fix`. No `.warning` row is made.
    - next: remove the structural duplication between `RuntimeDoctor.check(ofSkillsLayer:)` and `ConfigurationDoctor.check(of:)`, then run the review again.
  timestamp: 2026-09-09T04:44:12.247209+00:00
- actor: claude-code
  id: 01m227ptbtn9b6ya0v8r79x9r4
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 13 files, 4 new. `RuntimeDoctor` is the fifth and last component, category `runtime`: one row per skills-stack layer, missing is `.ok` because skills are optional, unreadable is an `.error` with a `chmod u+rx` fix, readable is `.ok`. A disabled `tools.skills` gives one passing row and reads no layer.
    - the Metal check is DROPPED, and the review agreed: `default.metallib` ships inside `mlx-swift_Cmlx.bundle`, SwiftPM puts that bundle beside the executable, and `Bundle.main` of a plain executable roots at the executable directory, so mlx finds it with no sibling file. The `mlx.metallib` symlink exists only because a `.xctest` binary sits two levels below its own bundle resources, which belongs to Router. A sibling-file check would report an error on every correct install. `cli-plan.md` §5.12's Runtime row is struck through and marked SUPERSEDED with the reason under the table, which the review judged the right record.
    - two helpers were extracted BEFORE anything was written twice, and the review confirmed the extraction keeps the behaviour: `ReadableDirectoryState` and `DisabledSectionCheck`. The tests of both existing components pass unedited.
    - test-first: red with "cannot find 'RuntimeDoctor' in scope" at DoctorRegistryTests.swift:61
    - test: green — swift test, 555 tests in 60 suites, 1 known issue at HarnessSmokeTests.swift:239. It was 550 in 59 before.
    - commit: 6142bae
    - review: findings — Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift:118
  timestamp: 2026-09-09T04:44:35.578624+00:00
- actor: claude-code
  id: 01m22865h7q6ayeqpdqfa2tkhv
  text: |
    ### The finding is answered: the three-case switch is written one time

    The finding, word for word:

    > `Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift:118`
    > `reuse/reuse` — The check(ofSkillsLayer:) method is 90% structurally
    > similar to ConfigurationDoctor.check(of:), duplicating the pattern of
    > building names, checking directory state, and returning domain-specific
    > HealthCheck results. A parameterized shared function would eliminate
    > this structural duplication. Extract a generalized helper function that
    > accepts parameters for the context noun ('configuration' or 'skills'),
    > the specific messages for each state, and a flag or closure for the
    > optional writability check. Both ConfigurationDoctor and RuntimeDoctor
    > can then call this shared function instead of maintaining parallel
    > implementations.

    New file `Doctor/DotfolderLayerCheck.swift`. It holds the whole shape one
    time: the check name, the three-case switch, the `chmod u+rx` fix and the
    write test. `DotfolderLayerCheck.Wording` carries the four words that
    change from one component to the next — the context noun, the reason a
    missing layer is no fault, what an unreadable layer costs, and what a
    person does beyond the `chmod` command. The write test is the option the
    finding asks for: `requiresWrite`.

    Both components are now one call each:

    - `ConfigurationDoctor.check(of:)` passes `requiresWrite: true`.
    - `RuntimeDoctor.check(ofSkillsLayer:)` passes `requiresWrite: false`.

    ### The messages come out byte-identical

    Each sentence is composed from the same skeleton and the component's own
    words, so every message and every fix is the same string as before:

    - configuration, missing: `<path> is not on disk, and the stack needs no file`
    - configuration, unreadable: `<path> cannot be read`, fix `chmod u+rx <path>`
    - configuration, not writable: `<path> cannot be written`, fix `chmod u+w <path>`
    - configuration, good: `<path> can be read and written`
    - skills, missing: `<path> is not on disk, and skills are optional`
    - skills, unreadable: `<path> cannot be read, so its skills are lost`, fix
      `chmod u+rx <path>, or remove it`
    - skills, good: `<path> can be read`

    The check names are the same too: `the <layer> layer` with no noun, and
    `the skills <layer> layer` with one. The noun is now
    `ToolCatalog.skillsDotfolderName`, which is the string `skills`, so the
    magic word is gone as well.

    `ConfigurationDoctorTests` and `RuntimeDoctorTests` are untouched. They
    are the guard, and both pass as they stand.

    ### No other component repeats the shape

    The whole `Doctor/` directory was read for the same three-case shape.
    Only these two components had it: `grep` for `ReadableDirectoryState`
    and `isReadableFile` over `Sources/` finds `ConfigurationDoctor`,
    `RuntimeDoctor` and the shared `ReadableDirectoryState` alone.
    `WritableDirectoryCheck` answers a different question — can the
    directory, or the nearest one above it, be written — and
    `TranscriptsDoctor` and `ToolsDoctor` already call the shared helpers.
    So nothing more was folded in.

    ### One design point, so the next agent does not undo it

    `DotfolderLayerCheck.Wording` has `var` properties with defaults and no
    `init` of its own. That is deliberate: the swiftformat gate rule
    `redundantMemberwiseInit` refuses a hand-written memberwise `init`, and a
    `let` property with a default value is left out of the synthesized
    memberwise `init` altogether. `var` with a default is the one shape that
    gives the caller default arguments and keeps the gate quiet.

    ### The gates

    - `swiftlint` with the gate's rule set and thresholds over the three
      files: clean.
    - `swiftformat --lint` with the roster and the gate's four options over
      the three files: clean.
    - `periphery scan` with the gate's retain flags: no finding on
      `DotfolderLayerCheck`, `Wording`, `writeFix` or `layerWording`.
  timestamp: 2026-09-09T04:52:58.535859+00:00
- actor: claude-code
  id: 01m22869q4fxsw6hrsrwm29yn2
  text: |-
    ### implement — changed
    - evidence: 3 files. New: Sources/FoundationModelsACPAgent/Doctor/DotfolderLayerCheck.swift. Changed: Sources/FoundationModelsACPAgent/Doctor/ConfigurationDoctor.swift, Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift. No test file was edited: this is a refactor, and the two unedited doctor suites are the guard. `swift test` gives 555 tests in 60 suites, 1 known issue at HarnessSmokeTests.swift:239, which is the same count as before the change.
    - next: /review
  timestamp: 2026-09-09T04:53:02.820627+00:00
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: doing
position_ordinal: '8180'
title: 'doctor checks: the skills stack, and the Metal runtime question'
---
### What

cli-plan.md §5.12, the Skills and Runtime rows. Split out of the tools
card.

`RuntimeDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`runtime`:

- **The skills stack is found.** `DotfolderStack(name: "skills")`
  resolves, and the layers that exist are readable. A missing stack is
  `.ok` — skills are optional — and an unreadable one is an `.error`.

**The Metal library check needs a definition before it can be built.**

cli-plan.md §5.12 says "The Metal shader library stands beside the
binary", but this repository has no `.metal` source and no checked-in
`.metallib`. The only colocation machinery is Router's
`MetalLibraryTestBootstrap`, reached solely from the nested integration
package, and it symlinks the library **in process, for tests only**.
`CIWorkflowTests.swift` records that this is why the
`integration-metallib-glob` CI knob is unnecessary. So the check has no
defined filename, no defined install location, and no artifact that
ships with an installed binary.

**Answer these three before writing the check**, and record the answers
in a task comment:

1. What is the exact library filename? (Read what
   `MetalLibraryTestBootstrap` looks for.)
2. Where must it stand, relative to an **installed** `acp-agent`?
3. What produces it there — mlx-swift's own bundle resource, or nothing
   at all?

If the answer to 3 is "nothing" — that is, an installed binary finds the
library through mlx-swift's resource bundle and never needs a sibling
file — then **drop the row** and say so in the comment. A check that
asserts against an invented target is worse than no check.

- [x] The skills stack check
- [x] Answer the three Metal questions in a task comment
- [x] Write the Metal check, or drop the row with the reason recorded
- [x] Register the component in the doctor list

### Acceptance Criteria

- [x] A missing skills stack gives `.ok`; an unreadable one gives an
      `.error` with a fix.
- [x] The task comment answers all three Metal questions.
- [x] If the Metal row survives, it names an exact filename and an exact
      path, and a fixture directory drives both the present and the
      absent case. (Not applicable: the row is dropped.)
- [x] If it is dropped, the comment says why, and cli-plan §5.12's
      Runtime row is noted as superseded.
- [x] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

- [x] `RuntimeDoctorTests`: the skills-present, skills-absent and
      skills-unreadable cases, against a temporary stack.
- [x] If the Metal row survives: the library-present and library-absent
      cases, against a temporary directory. (Not applicable.)
- [x] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-08 23:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `cli-plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Doctor/RuntimeDoctor.swift:118` `reuse/reuse` — The check(ofSkillsLayer:) method is 90% structurally similar to ConfigurationDoctor.check(of:), duplicating the pattern of building names, checking directory state, and returning domain-specific HealthCheck results. A parameterized shared function would eliminate this structural duplication. Extract a generalized helper function that accepts parameters for the context noun ('configuration' or 'skills'), the specific messages for each state, and a flag or closure for the optional writability check. Both ConfigurationDoctor and RuntimeDoctor can then call this shared function instead of maintaining parallel implementations.
