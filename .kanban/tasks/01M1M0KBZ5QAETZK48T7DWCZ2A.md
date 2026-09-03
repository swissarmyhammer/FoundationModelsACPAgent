---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1m4bhj3tk1zn9nmm532hrxx
  text: |-
    Picked up the card and did the research.

    Facts found:

    - `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` — `makeRegistry(context:)` gives the files capability `root: context.workingDirectory`, `additionalRoots: Set(context.additionalRoots)`, and the three `FilesToolOptions` flags. `sessionSurface(context:)` gives `makeSessionToolsAndStaging(librarian: context.profile.flash)`.
    - `Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift` — `FilesToolOptions.readOnly` is documented as "Whether the writing verbs are refused". This is the config option with a visible effect the card asks for.
    - `Tests/FoundationModelsACPAgentTestSupport/StubProfileFixtures.swift` — `StubModelLoader.makeLLMContainer` is a per-slot factory `(ModelSlot) -> any LoadedLLMContainer`. `ConfigOptionsTests.makeSlotLoader()` already uses it to make the flash slot answer a different text than the standard slot. This is the seam that can show the resolved profile arrived at the librarian slot.
    - `Tests/FoundationModelsACPAgentTestSupport/ScriptedModel.swift` — `PromptRecorder` records every prompt a scripted backend receives, and `ScriptedLLMContainer` accepts one.
    - `Tests/FoundationModelsACPAgentTests/Support/ScriptedTurnFixture.swift` — `make(loader:label:...)` accepts a per-slot loader and `additionalDirectories`, so proof 1 can drive a wire session with an additional root.

    Baseline before the change: root `swift test --filter TierTwoTests` = 7 tests green in 0.75 s.
  timestamp: 2026-09-03T17:16:38.339953+00:00
- actor: claude-code
  id: 01m1m4yyhd2gxq55rwq0ez8drz
  text: |-
    All three facts have an honest public reading. No fact was dropped.

    What proof 1 now does:

    1. The NAMES stay where they were, on the direct `ToolCatalog.makeRegistry` build. They cannot move to the wire: `help()` in the code-mode sandbox answers an array of path strings only (`MultiTool.swift`, `makeHelpDocsHostFunctions(for:)`), while `journalOp` and `group` are `APISurface.Entry` members. The suite header and the test doc comment now say this.

    2. The wire half runs one scripted tool turn on a session that has an additional root, a `tools.files.readOnly: true` project config, and a recording stub librarian on the flash slot. The snippet reads under the additional root, reads outside the root set, writes, and calls `tools.searchTools`. Each step reports a labeled outcome line.

    Evidence that each new assertion can fail. Each mutation was made in `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift`, watched, then removed:

    - `additionalRoots: Set(context.additionalRoots)` -> `additionalRoots: []` — the inside-read assertion failed. Message: `Expectation failed: waitText.contains(outcomeLine(label: insideReadLabel, value: additionalRootContent))`.
    - `readOnly: options.readOnly` -> `readOnly: false` — two assertions failed: the read-only correction line, and `!FileManager.default.fileExists(atPath: refusedWrite.path)`.
    - `librarian: context.profile.flash` -> `librarian: nil` — two assertions failed: `librarianPrompts.contains { $0.contains(librarianTask) }`, and `waitText.contains(executeVerbPath)`.

    Discovery found during the mutation runs: the whole `searchTools` answer carries each selected entry's documentation block. Without a librarian the answer is the full catalog, the tool return value goes over the 4000-character cap, and the truncated projection then loses the outcome lines. The snippet now reports only the opening of the answer (`searchAnswerReportLength`), so the outcome lines always survive. After that change the mutation runs still fail on the correct assertions.

    Upstream facts the design rests on (read in `.build/checkouts`, not changed):
    - `FoundationModelsMultitool/Capabilities/Files/Write.swift` — `readOnly` does not remove the write verb; the verb answers `correction: "The session is read-only, so the \`write\` verb cannot change files."`
    - `FoundationModelsMetadataRegistry/MetadataSearcher.swift` — in `.auto` mode a non-nil selection tier is always used, so every `searchTools` call is a real generate call on the librarian. There is no size threshold and no retrieval fallback.
    - `FoundationModelsRanker/Selection/Selection.swift` — a valid selection answer is `{"ids":[...]}`, which is what the stub librarian returns.

    `swift test` (root): 349 tests in 34 suites passed in 1.79 s, with the one pre-existing known issue in `HarnessSmokeTests`. No production file changed.
  timestamp: 2026-09-03T17:27:14.221392+00:00
- actor: claude-code
  id: 01m1m4zkfcs3h8kv8kfj8wrg7s
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift. Root `swift test`: 349 tests in 34 suites passed, 1 pre-existing known issue. No production file changed.
    - next: run the test step, then commit, then review.
  timestamp: 2026-09-03T17:27:35.660814+00:00
- actor: claude-code
  id: 01m1m50e1c3s0vpqp2khxbv1jf
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` clean; the one warning is the pre-existing SwiftPM `missing creator for mutated node` note about the mlx bundle, which is also on the untouched baseline. `swift test` — 349 tests in 34 suites passed in 1.82 s, 0 failed, 0 skipped, 1 pre-existing intentional known issue in `HarnessSmokeTests`.
    - next: commit, then review.
  timestamp: 2026-09-03T17:28:02.860232+00:00
- actor: claude-code
  id: 01m1m516czf56y3nfbkz9ddfag
  text: |-
    ### commit — changed
    - evidence: 103e6e5 test(tier-2): assert the CatalogContext the tools received, not only the names. 3 files changed, 292 insertions, 22 deletions. Local only; nothing pushed. `cli-plan.md` stays untracked, as the brief requires.
    - next: review HEAD~1..HEAD.
  timestamp: 2026-09-03T17:28:27.807082+00:00
- actor: claude-code
  id: 01m1m56p9g96511xccgm1zxqa9
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. The two `.kanban/` files were excluded by `.reviewignore`. No prior finding sections stood open.
    - next: none. The card moves to done.
  timestamp: 2026-09-03T17:31:27.920310+00:00
- actor: claude-code
  id: 01m1m56vms9x4r4snhbj7ddmp1
  text: |-
    ### finish iteration 1 — done
    - implement: changed. 1 file — `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift`. No production file changed.
    - test: green. 349 tests in 34 suites, 0 failed, 0 skipped, 1 pre-existing known issue.
    - commit: changed. 103e6e5.
    - review: clean. `review sha HEAD~1..HEAD` — 0 findings, 7 validators attempted.
    - All five acceptance criteria and both test items are complete. All three facts of plan.md §20.1 proof 1 have an honest reading and are asserted; none was dropped.
  timestamp: 2026-09-03T17:31:33.401962+00:00
position_column: done
position_ordinal: a680
title: 'Tier-2 proof 1: assert the CatalogContext the tools received, not only the surface names'
---
## What
`theCatalogComposesTheSurfaceFromTheLoadedConfiguration` in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift` carries the headline claim of tier 2 and proves the least of the seven proofs.

Plan.md §20.1 proof 1 asks: "`ToolCatalog` constructs each tool with the correct `CatalogContext`: the root set from `cwd` + `additionalDirectories`, that tool's decoded config section, and the resolved profile."

The test asserts only names on the built `APISurface`: the entry paths, two `journalOp` strings, and one `group`. It never asserts the root set. It never asserts that a config section reached the tool. It never asserts that the profile reached the librarian slot. **The test passes if every tool receives the wrong root set and the wrong profile.**

The test also never opens a wire, although the suite header says the seven proofs are "driven and asserted through `FoundationModelsACPClient`". Proof 1 is a direct unit call.

## Why
A composition proof that reads only names measures the naming, not the composition. The three facts the plan names are exactly the ones a defect would break silently: a session that confines to the wrong root, or a `searchTools` that selects with the wrong model.

## How
The per-verb structs are internal, which is the reason the current test gives. Assert through behavior instead, from the client end:

- **The root set.** A read of a file under an additional root succeeds, and a read outside the union is refused in band. `MultiRootConfinementTests` already drives this shape; do not duplicate it, but make proof 1 assert that the surface the catalog built is confined to the root set the session was given.
- **The config section.** Set one option in the `files` section that has a visible effect (`readOnly` is the clearest: a write is refused while a read succeeds), and prove the option reached the built tool.
- **The profile.** `searchTools` takes the flash slot as its librarian (`ToolCatalog.sessionSurface` passes `context.profile.flash`). Find a reading that shows the slot arrived — a recorded selection call against the stub profile, or an assertion on what the built session was handed. If no honest reading exists through a public door, say so on the card with file:line evidence and assert the two facts that can be proven, rather than leaving a comment that promises three.

Keep the existing name assertions. They are cheap and they catch a mount-order change.

## Acceptance Criteria
- [x] Proof 1 asserts the root set the built tools actually enforce, through the wire
- [x] Proof 1 asserts that a decoded config option reached the tool it belongs to, through visible behavior
- [x] Proof 1 asserts the resolved profile reached the slot that consumes it, or the card records with file:line evidence that no public door exposes it
- [x] The suite header and the test's doc comment describe only what the body asserts
- [x] `swift test` → green

## Tests
- [x] The extended `theCatalogComposesTheSurfaceFromTheLoadedConfiguration`
- [x] Each new assertion watched to fail first, against the current code

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.