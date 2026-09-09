---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m225a871exs1jyqvbf0gwxp6
  text: |
    Research, and the two decisions the card left open.

    **The seam.** `ProfileDoctor` follows the `ToolsDoctor` pattern exactly: one injected protocol, `ModelResolver`, whose one call is `lookUp(_ reference: ModelRef) async -> ModelLookup`. `ModelLookup` carries `found(downloadBytes:)`, `notFound`, `unreachable(reason:)` and `noAnswer`. One value gives the resolve row AND the cache row: `downloadBytes == 0` means the cache already holds every file. `SystemModelResolver` is the real one; it reads the repository tree through Router's public `HuggingFaceMetadataSource` and compares that tree with the local hub cache. No unit test builds it.

    **Reuse, not a third copy.** `ProbeTimeout` was inside `ToolsProber.swift` and was fixed to `ProbeOutcome`. It is now `Doctor/ProbeTimeout.swift`, generic over the answer, and each component states its own late answer (`.timedOut` for the tools, `.noAnswer` for the profile). `MachineFigures.freeDiskBytes(at:)` reuses `WritableDirectoryCheck.nearestExistingDirectory(of:)`, because a model cache that is not on disk yet has no volume of its own. No helper was copied.

    **Decision 1 — the memory figure.** The card says compare the trio against the injected figure, and the brief says do not invent an arithmetic of your own. I read the real `JointFit` in Router: it prices the three slots against one shared budget and it needs the repository metadata of each candidate to do it (`footprint`, `sessionBytes`, `nativeMaxContext` closures). This check reads no such metadata, so it does no pricing. It compares the machine with the 32 GB floor cli-plan.md §7 measured for the shipped trio, and it applies that same floor to a profile that names other models. The reason is written on `ProfileDoctor.memoryFloorBytes`.

    **Decision 2 — the smaller profile a fix names.** The error names both figures and tells a person to set `profile.standard` to a smaller model, and it names `ProfileConfiguration.defaultFlash` as that model, because it is a 4B build this package already ships and it fits a 16 GB machine. No new model string entered the code.

    **The rows.** Per reference, in slot order standard, flash, embedding: the shape row; then, when the shape passes, the resolve row, the cache row, and the MTP row when the id holds `-MTP-`. Then the memory row and the disk row. A malformed reference is never looked up.

    **Not touched.** No change in Router or any other sibling.
  timestamp: 2026-09-09T04:02:46.625490+00:00
- actor: claude-code
  id: 01m225afy8m49803bvb7hpdkhb
  text: |
    ### implement — changed
    - evidence: 6 new files — `Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift`, `.../Doctor/ModelResolver.swift`, `.../Doctor/MachineFigures.swift`, `.../Doctor/ProbeTimeout.swift`, `Tests/FoundationModelsACPAgentTests/Doctor/ProfileDoctorTests.swift`, `Tests/FoundationModelsACPAgentTests/Support/StubModelResolver.swift`. 4 changed — `Sources/acp-agent/DoctorCommand.swift` (registered second), `.../Doctor/ToolsProber.swift` (the timeout moved out), `.../Doctor/ToolsDoctor.swift` (the new call), `.../Doctor/WritableDirectoryCheck.swift` (the walk is now shared), `Tests/.../Doctor/DoctorRegistryTests.swift` (four components).
    - tdd: red first. `swift test --filter 'ProfileDoctorTests|DoctorRegistryTests'` against a `ProfileDoctor` whose `runHealthChecks()` returned `[]` gave 12 failures in 14 tests. After the implementation the same filter gave 27 of 27 passed.
    - tests: `swift test` gives 550 tests in 59 suites passed, 1 known issue. The baseline was 536 in 58 with the same 1 known issue, so 14 tests entered and 1 suite entered. No warning, and no network in any of them.
    - next: `/review`.
  timestamp: 2026-09-09T04:02:54.536926+00:00
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: doing
position_ordinal: '8180'
title: 'doctor checks: the profile — model ids, memory fit, disk and MTP'
---
### What

cli-plan.md §5.12, row 2. This is the row that earns the whole command.
A wrong model repository id and a profile that does not fit the machine
are the two failures a person cannot diagnose from the error Router
raises.

`ProfileDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`profile`. **Every external fact it needs is injected**: a resolver
protocol for the Hugging Face lookup, a memory figure, and a free-disk
figure. No test touches the network, and no acceptance criterion depends
on the machine it runs on.

It reports:

1. **Each model reference is well formed** — `owner/name`, no empty
   part, no whitespace. Malformed is an `.error` naming the slot.
2. **Each one resolves.** Through the injected resolver. Not found is an
   `.error` naming the slot and the id, with a fix that names
   `acp-agent config edit`. A network failure is a `.warning`, not an
   `.error`: an offline machine with a warm cache still works.
3. **Cache state.** Is it already on disk? This tells a person whether
   the next run downloads.
4. **The trio fits the machine's memory.** Compare against the injected
   figure. Under the floor is an `.error` naming both numbers and the
   smaller profile to choose.
5. **The free disk covers what must still be downloaded.**
6. **MTP.** A slot whose id holds `-MTP-` is a `.warning`: Router calls
   the plain generate path and never reads the MTP head, so the download
   is larger and the speed is the same. See §7.1.

**Name the resolver timeout in seconds in the code.** The criterion
below asserts against that named value.

- [x] The shape check
- [x] The resolve check, over an injected resolver, with a named timeout
- [x] The cache-state row
- [x] The memory-fit and free-disk rows, over injected figures
- [x] The MTP warning row
- [x] Register it in the doctor component list

### Acceptance Criteria

- [x] A malformed id gives an `.error` naming the slot.
- [x] An injected not-found gives an `.error`; an injected network
      failure gives a `.warning`.
- [x] An injected memory figure below the profile's need gives an
      `.error` stating both figures.
- [x] A slot naming an MTP model gives exactly one `.warning`; the
      shipped defaults give none.
- [x] With an all-found resolver, a generous memory figure and a
      generous disk figure, every row is `.ok` or a cache-state note.
      **This is the fixture, not the real machine.**
- [x] A resolver that never answers gives a `.warning`, and the elapsed
      time is under the named timeout.
- [x] Every `.warning` and every `.error` carries a non-nil `fix`.

### Tests

- [x] `ProfileDoctorTests`: well-formed and malformed ids, with no
      network.
- [x] The resolver cases: found, not found, network failure, timeout —
      all through the injected resolver.
- [x] The memory-fit case, with an injected small figure, asserting the
      `.error` message names both numbers.
- [x] The MTP case: a configuration whose `flash` names
      `mlx-community/Qwen3.5-9B-MTP-4bit` gives one `.warning`; the
      shipped defaults give none.
- [x] The timeout test asserts the elapsed time is under the named
      bound, and that the check returns rather than hanging.
- [x] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
