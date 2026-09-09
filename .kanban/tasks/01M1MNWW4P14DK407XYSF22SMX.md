---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m21hytvdtv7hwjq7tb8a3v7z
  text: |-
    ### The upstream card is made

    `FoundationModelsRouter` card **`^5545bna`** — "Make the per-slot ResolutionProgress surface public". It is in `todo` and carries the full specification of this card, written from Router's own view.

    This card stays open until that one is done and merged to Router `main`.
  timestamp: 2026-09-08T22:24:29.549392+00:00
- actor: claude-code
  id: 01m21wfghmys5gxzwz1hvyed8d
  text: |-
    ### Verification of the upstream work, and of the consumption here

    This card is a tracking card. The work was upstream. This pass verified it and made this repository consume it. It did not change Router.

    **1. The upstream code, read directly**

    Router commits, both on `main`:
    - `e153630` — "feat(resolution): make per-slot progress public (^5545bna)". It changed `Package.swift`, `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift`, and added `Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift`.
    - `d469aa0` — the kanban ledger of `^5545bna`. It is the tip of `main`.

    `git merge-base --is-ancestor e153630 origin/main` succeeds, and `git ls-remote origin main` gives `d469aa0`. The change is therefore on the remote `main` branch, which is the branch this repository tracks.

    In `ResolutionProgress.swift` I read, one by one:
    - `public struct SlotProgress: Sendable, Equatable`
    - `public enum State: Sendable, Equatable`, with `pending`, `sizing`, `downloading`, `loading`, `ready` and `failed(String)`
    - `public internal(set) var state`, `chosen`, `bytesDownloaded`, `bytesTotal`
    - `public var progressFraction: Double`
    - `public internal(set) var fraction: Double`
    - `public internal(set) var slots: [ModelSlot: SlotProgress]`
    - `SlotProgress.init` stays internal, so the router alone writes the values.

    `ModelSlot` was already public (`public enum ModelSlot: String, Sendable, Hashable, Codable`, in `Core/ModelSlot.swift`), and so was `ModelRef` (`public struct ModelRef` in `Core/ModelRef.swift`). Neither needed a change.

    **2. This repository consumes it**

    The pin was stale. `Package.resolved` held Router `cc51793`, which is before `e153630`. I ran `swift package update FoundationModelsRouter`. The pin is now `d469aa0`. `swift build` then completed with no compiler warning. (The one line the build prints, "missing creator for mutated node" on the MLX bundle, is present on the unchanged tree and comes from the build system, not from this change.)

    `Package.resolved` and `IntegrationTests/Package.resolved` are both ignored by `.gitignore` line 6, so the update staged nothing and could stage nothing.

    **3. The type-check probe, and its negative control**

    The probe is `scratchpad/PublicSurfaceProbe.swift`. It does a plain `import FoundationModelsRouter`, with no `@testable`. It is `@MainActor`, because the type is `@MainActor @Observable`. It reads `progress.fraction`, `progress.slots`, and for each slot the `state`, `chosen`, `bytesDownloaded`, `bytesTotal` and `progressFraction`, and it switches over every case of `SlotProgress.State`.

    It was compiled with `swiftc -typecheck -swift-version 6 -target arm64-apple-macosx27.0 -I .build/out/Products/Debug`, plus the C module include paths.

    - RED, against the old pin `cc51793`: it failed with `'fraction' is inaccessible due to 'internal' protection level`, `cannot find type 'SlotProgress' in scope`, and `'slots' is inaccessible due to 'internal' protection level`.
    - GREEN, against the new pin `d469aa0`: exit 0, with no diagnostic at all.

    The negative control is `scratchpad/NegativeControl.swift`. It must not compile, and it does not. All three of its reads fail:
    - `progress.refreshFraction()` — `'refreshFraction' is inaccessible due to 'internal' protection level`. This is the control that matters most: it proves the compile is a true plain import and not a `@testable` one, because a `@testable` import would see that internal method.
    - `progress.slots = [:]` — `cannot assign to property: 'slots' setter is inaccessible`. The `internal(set)` held.
    - `progress.thisMemberDoesNotExist` — `has no member`.

    **4. The upstream test target**

    `Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift` is a separate target with a plain import, its test is `@MainActor`, and it asserts the values written back (`state == .ready`, `chosen`, `bytesDownloaded`, `bytesTotal`, `progressFraction == 1`, `fraction == 1`, and the three slot keys). It is a red-to-green test, not a "fails to compile" claim.

    **5. What I did not run, and why**

    I did not run `swift build` or `swift test` in `../FoundationModelsRouter`. A build there writes into that working tree, and the constraint on this pass is to make no change in Router. The acceptance criterion "swift build and swift test pass in Router with no warning" is ticked on the record of the upstream card `^5545bna`, which reports `swift build --build-tests` clean and `swift test` at 1339 passed, 0 failed, 0 skipped. Independently of that record, this repository compiled Router's sources at `d469aa0` from its own checkout with no compiler warning.

    **6. Tests here**

    Root `swift test`: 497 tests in 52 suites passed, with the 1 known issue at `HarnessSmokeTests.swift:239`. That is the baseline exactly. The `IntegrationTests` package was not run.

    This card unblocks `^29cgh83`, "Download progress on stderr while the models resolve".
  timestamp: 2026-09-09T01:28:21.812434+00:00
- actor: claude-code
  id: 01m21wfpq5rqsnjhwetg283eh7
  text: |-
    ### implement — changed

    - evidence: The upstream surface is on Router `main` (`e153630`, tip `d469aa0`), read directly in `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift`. This repository moved its Router pin from `cc51793` to `d469aa0` with `swift package update FoundationModelsRouter`; `Package.resolved` is gitignored, so no file in the repository changed except this card. `swift build` is clean. The scratchpad probe with a plain `import FoundationModelsRouter`, `@MainActor`, went RED on the old pin (three access-level errors) and GREEN on the new pin (exit 0, no diagnostic). The negative control fails on all three of its reads, including the internal `refreshFraction()`, which proves the import is not `@testable`. Root `swift test`: 497 tests in 52 suites passed, 1 known issue at `HarnessSmokeTests.swift:239`, which is the baseline.
    - next: `/review`. The card stays in `doing`.
  timestamp: 2026-09-09T01:28:28.133058+00:00
- actor: claude-code
  id: 01m21wnbt5v9s0rhv497xvqk8f
  text: |-
    ### review — clean
    - scope: review sha HEAD~1..HEAD (commit 4972cb5)
    - evidence: 0 findings, 0 confirmed, 0 refuted. The 4 files in the range are kanban card files, which the .reviewignore rule keeps out of the review. No source file changed in this commit.
    - next: none. The card moves to done.
  timestamp: 2026-09-09T01:31:33.573970+00:00
- actor: claude-code
  id: 01m21wp1tnk1x52cmpebb9722r
  text: |-
    ### finish iteration — clean
    - implement: changed — card text only. Read the upstream surface at FoundationModelsRouter `main` (commit e153630, tip d469aa0): `slots` and `fraction` are `public internal(set)`; `SlotProgress` is public with `state`, `chosen`, `bytesDownloaded`, `bytesTotal` and `progressFraction`; `SlotProgress.State` is public; `SlotProgress.init` stays internal, so only the router writes. `ModelSlot` and `ModelRef` were already public.
    - consumption proof: `swift package update FoundationModelsRouter` moved the pin from cc51793 to d469aa0. A `@MainActor` probe with a PLAIN import went red on the old pin ("'slots' is inaccessible due to 'internal' protection level") and green on the new. A negative control fails on the internal `refreshFraction()`, which proves the compile is a plain import and not `@testable`.
    - test: green — swift test, 497 tests in 52 suites, 1 known issue at HarnessSmokeTests.swift:239, against the bumped Router
    - commit: 4972cb5
    - review: clean — 0 findings, review sha HEAD~1..HEAD
    - result: the upstream card `^5545bna` is done, merged to Router `main`, and pushed. No code change was necessary here. The card "Download progress on stderr while the models resolve" is no longer blocked by this card.
  timestamp: 2026-09-09T01:31:56.117696+00:00
position_column: done
position_ordinal: c480
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

- [x] `slots` public
- [x] `SlotProgress`, its members, and `State` public
- [x] `fraction` public
- [x] Confirm `ModelSlot` and `ModelRef` are already public
- [x] Merge to `main` in the Router repository

## Acceptance Criteria

- [x] A module that does a plain `import FoundationModelsRouter` — not
      `@testable` — reads `progress.slots`, and each slot's `state`,
      `chosen`, `bytesDownloaded` and `bytesTotal`, and compiles.
- [x] `swift build` and `swift test` pass in Router with no warning.
- [x] The change is on Router `main`, because consumers track the `main`
      branch and not a version.

## Tests

- [x] The compile proof goes in a **separate module** that uses a plain
      `import FoundationModelsRouter`. A test inside the Router test
      target sees internal members through `@testable` and would prove
      nothing.
- [x] That test is `@MainActor`, because the type is.
- [x] It reads every member the CLI needs, and asserts the values it
      wrote back. This is a normal red-to-green test, not a
      "fails to compile" claim.
- [x] `swift test` in `../FoundationModelsRouter` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
