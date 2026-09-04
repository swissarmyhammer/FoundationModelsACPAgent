---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Router: make the per-slot ResolutionProgress surface public'
---
## What

Upstream work in `../FoundationModelsRouter`. It unblocks the CLI
download progress (cli-plan.md §5.7).

**Correction to the earlier framing.** The overall fraction is *already*
reachable: `ResolutionProgress` publishes
`public var phases: AsyncStream<PhaseTransition>` with
`public typealias PhaseTransition = (phase: Phase, fraction: Double)`.
Only the **per-slot** surface is missing, and that is what a bar with
byte counts needs.

In `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift`:

- `var slots: [ModelSlot: SlotProgress]` becomes public.
- `SlotProgress` becomes public, with its `state`, `chosen`,
  `bytesDownloaded`, `bytesTotal` and `progressFraction`.
- `SlotProgress.State` becomes public.
- `ModelSlot` and `ModelRef` are **already public**
  (`Core/ModelSlot.swift:5`, and `ModelRef` appears in
  `public static let defaultStandard: [ModelRef]`), so they need no
  change. Confirm this before you start.
- Make `fraction` public too, for a consumer that wants it without
  subscribing to `phases`.

**Two constraints the implementer must plan for:**

1. The type is `@MainActor @Observable public final class`. Every
   consumer read is a main-actor hop, and the CLI card
   (`29cgh83`) states the same constraint.
2. Changing the access level of an `@Observable` stored property is not
   a keyword edit — the macro generates the observation plumbing, so
   check that the expanded accessors keep the intended access and that
   the build stays warning-free.

- [ ] `slots` public
- [ ] `SlotProgress`, its members, and `State` public
- [ ] `fraction` public
- [ ] Confirm `ModelSlot` and `ModelRef` are already public
- [ ] Merge to `main` in the Router repository

## Acceptance Criteria

- [ ] A module that does a plain `import FoundationModelsRouter` — not
      `@testable` — reads `progress.slots`, and each slot's `state`,
      `chosen`, `bytesDownloaded` and `bytesTotal`, and compiles.
- [ ] `swift build` and `swift test` pass in Router with no warning.
- [ ] The change is on Router `main`, because consumers track the `main`
      branch and not a version.

## Tests

- [ ] The compile proof goes in a **separate module** that uses a plain
      `import FoundationModelsRouter`. A test inside the Router test
      target sees internal members through `@testable` and would prove
      nothing.
- [ ] That test is `@MainActor`, because the type is.
- [ ] It reads every member the CLI needs, and asserts the values it
      wrote back. This is a normal red-to-green test, not a
      "fails to compile" claim.
- [ ] `swift test` in `../FoundationModelsRouter` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.