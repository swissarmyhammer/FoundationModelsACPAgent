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
- actor: claude-code
  id: 01m225ws4scd20pmq4c1fhb7v7
  text: |
    ### review — findings
    - evidence: 1 finding — Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift:81 (scope: review sha HEAD~1..HEAD; 1 confirmed, 3 refuted, 7 attempted)
    - next: put the two separator constants in one shared place, then review the card again.
  timestamp: 2026-09-09T04:12:53.785294+00:00
- actor: claude-code
  id: 01m225x95meh5nvz4rgjcgntf3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files, 6 new. `ProfileDoctor` is registered second. Per reference, in slot order: the shape row, then the resolve row, the cache-state row and an MTP row when the id holds `-MTP-`; then one memory row and one free-disk row. A malformed reference is never looked up.
    - `ModelResolver.lookUp(_:)` is the injected seam. `ProbeTimeout` moved into its own file and is generic, so `ToolsDoctor` and `ProfileDoctor` share one copy.
    - two deliberate limits, both accepted by the review: the memory row does NO `JointFit` pricing, because Router's `JointFit` needs per-candidate repository metadata this check does not read; it compares the machine with the measured 32 GB floor. The "smaller profile" a fix names is `ProfileConfiguration.defaultFlash`, so no new model string entered the code.
    - test-first: 12 of 14 ProfileDoctorTests failed against a stub returning an empty list
    - test: green — swift test, 550 tests in 59 suites, 1 known issue at HarnessSmokeTests.swift:239. It was 536 in 58 before. The suite ran ten times with no flakiness, and reaches no network, no real Hugging Face cache and no machine-dependent figure.
    - commit: 637c41b
    - review: findings — Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift:81. The review refuted three other candidates, and the `ProbeTimeout` move drew no finding.
  timestamp: 2026-09-09T04:13:10.196338+00:00
- actor: claude-code
  id: 01m22698xbvwyvtje49055ksny
  text: |
    The one finding is answered. What I found first, and where the separators now stand.

    **The format already has an owner, and the owner keeps it private.** Router's `ModelRef` (`FoundationModelsRouter/Sources/FoundationModelsRouter/Core/ModelRef.swift`) parses the same two separators and holds the two parts. But `repo` and `revision` are `internal`, and its own `revisionSeparator` is `private`, so no other package can read any of the three. To read them from here, Router must widen that access, and a Router change is not this card's — it needs its own card on that project, discussed first. Nothing in Router was touched.

    **No existing type here declares them either.** `ProfileConfiguration` and `AgentConfiguration` hold `[ModelRef]` values, but they state no separator: they leave every reference to `ModelRef`. So this package had no home for the format, and the two new files each made one.

    **The home I picked, inside this repository.** `Sources/FoundationModelsACPAgent/Configuration/ModelReferenceFormat.swift`, a small `internal enum`. It stands in `Configuration/`, beside the `profile:` section whose slots hold the references, because the format belongs to the model reference and not to `doctor`. It is `internal`, because both readers are in this module. It states:

    - `ownerSeparator` — the `/` between the owner and the name.
    - `revisionSeparator` — the `@` before a pinned revision.
    - `parts(of:)` — the repository id and the revision of one reference.

    **Both separators were written twice, not one.** The finding names `revisionSeparator`, and it says "the separators" in the plural. `ownerSeparator` was the other one: `"/"` as a `String` in `ModelResolver` and as a `Character` in `ProfileDoctor`. Both are gone from both files. The **parse** was written twice as well, which is the same cause one step further: `ModelResolver.parts(of:)` split the reference at `@`, and `ProfileDoctor.isWellFormed` took the same prefix by hand. One `ModelReferenceFormat.parts(of:)` now answers both, so a change to the format goes in one file.

    No other reference-format constant is written twice across the files this card added. `mtpMark` (`-MTP-`) stands once, in `ProfileDoctor`. The slot keys already compose over the shared `LoadedConfiguration.keyPathSeparator`. `cacheSeparator` (`--`) stays in `ModelResolver`: it is the shape of a cache directory name, not of a reference, and it has one reader.

    **One thing I saw and did not touch.** `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` declares its own `modelOwnerSeparator: Character = "/"`. That file is not one this card added, and the duplication rule puts the fix in the changed code and not in the counterpart. It can now read `ModelReferenceFormat.ownerSeparator` through `@testable import`, which is a separate small piece of work.
  timestamp: 2026-09-09T04:19:43.147140+00:00
- actor: claude-code
  id: 01m2269d90hye68r3jdcftwpsc
  text: |
    ### implement — changed
    - evidence: 3 files — 1 new, `Sources/FoundationModelsACPAgent/Configuration/ModelReferenceFormat.swift`; 2 changed, `Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift` and `Sources/FoundationModelsACPAgent/Doctor/ProfileDoctor.swift`. `swift test` gives 550 tests in 59 suites passed, 1 known issue at HarnessSmokeTests.swift:239 — the same count as before, because this is a refactor and it adds no coverage. `swift build` reports no warning of this package. No IntegrationTests run. No commit.
    - next: `/review`.
  timestamp: 2026-09-09T04:19:47.616613+00:00
- actor: claude-code
  id: 01m226hk4aqnsjz9s28c05xg10
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (2fa0a51) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed; 3 files reviewed, 2 excluded by `.reviewignore`.
    - The finding of the round before is closed. `revisionSeparator` and `ownerSeparator` are now in one file, `Sources/FoundationModelsACPAgent/Configuration/ModelReferenceFormat.swift`, and both Doctor files read that copy. The two parse bodies are now the one function `ModelReferenceFormat.parts(of:)`, and it gives the same result as the code it replaced.
    - next: no work is open on this card.
  timestamp: 2026-09-09T04:24:15.754802+00:00
- actor: claude-code
  id: 01m226j6jsshf927a0j28w9bef
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files. The reference-format constants and the parse moved into the new `Sources/FoundationModelsACPAgent/Configuration/ModelReferenceFormat.swift`. Both `ModelResolver.swift` and `ProfileDoctor.swift` read the one copy.
    - what was checked before the home was picked: Router's `ModelRef` owns the format, but it keeps `repo`, `revision` and its own separator private, so using it needs a Router change. Router was not touched. `ProfileConfiguration` and `AgentConfiguration` state no separator, so this repository had no existing home either.
    - the same cause was removed from the whole change: `ownerSeparator` was a second duplicated separator, and the PARSE was duplicated as well. `cacheSeparator` stays in `ModelResolver`, because it names a cache directory and not a reference.
    - test: green — swift test, 550 tests in 59 suites, 1 known issue at HarnessSmokeTests.swift:239. The count is unchanged, which is correct for a refactor. The malformed-reference behaviour holds: exactly one error, and it is still never looked up.
    - commit: 2fa0a51
    - review: clean — 0 findings. The review confirmed the moved parse keeps the same behaviour, and recorded no finding on the choice of home.
    - separate work, not this card: `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift` declares its own owner separator. That file is not one this card added, so it was left alone.
  timestamp: 2026-09-09T04:24:35.673164+00:00
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: done
position_ordinal: cb80
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

## Review Findings (2026-09-08 23:08)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift:81` `duplication/duplication` — The constant `revisionSeparator` is duplicated verbatim in ProfileDoctor.swift at line 60. Both use `"@"` to separate a model reference from its pinned revision. This is a changed-set duplicate — both are new and should be extracted to a shared location. See suggestion for ownerSeparator above — extract both separators to a shared location so a future change to the reference format need only touch one place.
