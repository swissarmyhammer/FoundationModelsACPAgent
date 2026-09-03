---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Tier-2 proof 1: assert the CatalogContext the tools received, not only the surface names'
---
## What
`theCatalogComposesTheSurfaceFromTheLoadedConfiguration` in `Tests/FoundationModelsACPAgentTests/Integration/TierTwoTests.swift:334` carries the headline claim of tier 2 and proves the least of the seven proofs.

Plan.md §20.1 proof 1 asks: "`ToolCatalog` constructs each tool with the correct `CatalogContext`: the root set from `cwd` + `additionalDirectories`, that tool's decoded config section, and the resolved profile."

The test asserts only names on the built `APISurface`: the entry paths, two `journalOp` strings, and one `group`. It never asserts the root set. It never asserts that a config section reached the tool. It never asserts that the profile reached the librarian slot. **The test passes if every tool receives the wrong root set and the wrong profile.**

The test also never opens a wire, although the suite header at line 15 says the seven proofs are "driven and asserted through `FoundationModelsACPClient`". Proof 1 is a direct unit call.

## Why
A composition proof that reads only names measures the naming, not the composition. The three facts the plan names are exactly the ones a defect would break silently: a session that confines to the wrong root, or a `searchTools` that selects with the wrong model.

## How
The per-verb structs are internal, which is the reason the current test gives at line 332. Assert through behavior instead, from the client end:

- **The root set.** A read of a file under an additional root succeeds, and a read outside the union is refused in band. `MultiRootConfinementTests` already drives this shape; do not duplicate it, but make proof 1 assert that the surface the catalog built is confined to the root set the session was given.
- **The config section.** Set one option in the `files` section that has a visible effect (`readOnly` is the clearest: a write is refused while a read succeeds), and prove the option reached the built tool.
- **The profile.** `searchTools` takes the flash slot as its librarian (`ToolCatalog.sessionSurface` passes `context.profile.flash`). Find a reading that shows the slot arrived — a recorded selection call against the stub profile, or an assertion on what the built session was handed. If no honest reading exists through a public door, say so on the card with file:line evidence and assert the two facts that can be proven, rather than leaving a comment that promises three.

Keep the existing name assertions. They are cheap and they catch a mount-order change.

## Acceptance Criteria
- [ ] Proof 1 asserts the root set the built tools actually enforce, through the wire
- [ ] Proof 1 asserts that a decoded config option reached the tool it belongs to, through visible behavior
- [ ] Proof 1 asserts the resolved profile reached the slot that consumes it, or the card records with file:line evidence that no public door exposes it
- [ ] The suite header and the test's doc comment describe only what the body asserts
- [ ] `swift test` → green

## Tests
- [ ] The extended `theCatalogComposesTheSurfaceFromTheLoadedConfiguration`
- [ ] Each new assertion watched to fail first, against the current code

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.