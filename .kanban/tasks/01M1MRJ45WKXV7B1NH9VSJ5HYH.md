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