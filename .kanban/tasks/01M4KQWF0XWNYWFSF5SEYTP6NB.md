---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4mjd1j8v1g5bwss5ymwngsn
  text: |-
    ### Research and experiments (2026-10-10)

    Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0. `xcrun --find swift` gives the Xcode default toolchain. No other toolchain is on this machine (`/Library/Developer/Toolchains` and `~/Library/Developer/Toolchains` do not exist). Thus "a newer SwiftPM" is not available here.

    swift-otel 1.5.1 declares the three grpc packages in `dependencies:` without a condition. Only the PRODUCT dependencies have `.when(traits: ["OTLPGRPC"])`. Default traits: `OTLPHTTP` and `OTLPGRPC`.

    Each experiment is a minimal scratch package (one executable target that links `OTel`), with its own `--scratch-path`, Swift 6.4:

    | Form | Manifest | `update` | grpc pin |
    |---|---|---|---|
    | A | root: `.package(url: swift-otel, from: "1.5.1", traits: ["OTLPHTTP"])` (the current form) | FAIL: "exhausted attempts ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf" | - |
    | A2 | form A, `resolve` | PASS | 0 |
    | A3 | form A, `update swift-otel` from a resolved state | FAIL (same error) | - |
    | B | root: `traits: [.trait(name: "OTLPHTTP")]` | FAIL (same error) | - |
    | C | root: `traits: []` | FAIL: the error also names swift-nio-ssl and swift-protobuf | - |
    | G | root trait `HTTPExport` (default) and dependency trait `.trait(name: "OTLPHTTP", condition: .when(traits: ["HTTPExport"]))` | FAIL (same error) | - |
    | D | root does not declare swift-otel; a LOCAL path package W declares swift-otel with `["OTLPHTTP"]`; root target links W | PASS (2 fresh runs, and `update swift-otel`) | 0 |
    | E | form A AND a local path package W that declares swift-otel with `["OTLPHTTP"]`; root target links W | PASS (2 fresh runs, and `update swift-otel`) | 0 |
    | F | form E, but no root target links W | PASS, but each graph load writes "warning: 'f': dependency 'w' is not used by any target" | 0 |

    D and E give the same pin set as the `resolve` of form A (26 pins, async-http-client is in, no grpc), thus the OTLPHTTP trait is live and gRPC is out of the graph.

    Conclusion: SwiftPM 6.4 `update` drops the traits that the ROOT manifest sets on a dependency, but it keeps the traits that a NON-ROOT manifest sets. A local path package is a non-root node, and that is sufficient.

    Chosen form: E. It keeps the root declaration of swift-otel and its product (no source change, `resolve` and build stay the same), and it adds one small local package that only carries the trait. When SwiftPM is fixed, the workaround is one folder and two manifest lines to remove. F is rejected because of the unused-dependency warning.
  timestamp: 2026-10-11T04:09:13.032081+00:00
- actor: claude-code
  id: 01m4mjybkszj60w241ejs7s2e9
  text: |-
    ### Form E in the root: not reliable

    Form E applied to the root (`OTelTraitCarrier/` local package, root keeps its own swift-otel declaration, `acp-agent` links the carrier product):

    - run 1, `swift package --scratch-path <fresh> update swift-otel`: PASS, Package.resolved byte-identical to the backup, no grpc pin, no grpc checkout.
    - run 2, the README command (same, fresh scratch path): FAIL, "exhausted attempts ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf". Package.resolved was not changed.
    - run 3, full `swift package update` in a scratch copy of the root: PASS, no grpc pin.

    Thus E only moves the race. Upstream explains it: swiftlang/swift-package-manager#10397 ("exhausted attempts to resolve the dependencies graph" after `update`), closed by PR #10547 "Seed root manifest traits when loading dependency manifests": `update` clears the trait map and does not reload the root, so the root entry reads back as a placeholder (default traits). PR #10579 (open) fixes trait sets that depend on manifest load order. The fix of #10547 is cherry-picked into `release/6.4.1` (PR #10577, merged 2026-09-24). This machine has 6.4.0 (swiftlang-6.4.0.34.1).

    Because a fix exists upstream, no new upstream report is necessary.

    Next: form D in the root (the root does NOT declare swift-otel; only the local carrier does, so no root entry can add the default traits). No other package in the graph declares swift-otel (Router, Extras, Multitool, Agents, CodeContext and MetadataRegistry only name it in comments). Measuring E and D with 3 fresh runs each on scratch copies of the root.
  timestamp: 2026-10-11T04:18:40.377470+00:00
- actor: claude-code
  id: 01m4mm76dnf1f5j7tkj3cnffyw
  text: |-
    ### Form D chosen and applied to the root

    Repeat measurement (`swift package --scratch-path <fresh> update swift-otel`, each run from the original Package.resolved):

    | Form | Where | Runs | Pass |
    |---|---|---|---|
    | E (root declares swift-otel + local carrier) | root | 2 | 1 (README-command run failed with the grpc error) |
    | E | scratch copies of the root | 3 + 5 (+1 full `update`) | 9 of 9 |
    | D (only a local package declares swift-otel) | scratch copies of the root | 3 + 6 | 9 of 9 |
    | D | the real root, README command verbatim | 3 | 3 of 3 |

    E fails sometimes (about 1 in 12 here); D did not fail. D also matches the upstream mechanism (PR #10547): `update` clears the enabled-traits map and does not load the root again, so only the requests of the ROOT manifest are lost. A local path package is loaded again as a dependency. In D the root makes no request on swift-otel, so nothing can be lost.

    Changes:
    - New local package `OTelHTTP/` (`Package.swift`, `Sources/OTelHTTP/OTelHTTP.swift`): declares swift-otel `from: "1.5.1"` with traits `["OTLPHTTP"]`; the module does `@_exported import OTel`.
    - `Package.swift`: the root no longer declares swift-otel. It declares `.package(path: "OTelHTTP")`; `acp-agent` links the `OTelHTTP` product in place of the `OTel` product. Doc comments name the defect and the 6.4.1 fix.
    - `Sources/acp-agent/TelemetryBootstrap.swift`: `import OTel` -> `import OTelHTTP` (the target imports the product it declares).
    - `README.md` (Documentation section): the proof command `swift package --scratch-path "$(mktemp -d)" update swift-otel && ! grep -q '"identity" : "grpc-' Package.resolved && echo "update passes; no grpc pin"`.

    Checks:
    - `swift build --scratch-path .build/alt --force-resolved-versions`: Build complete. One warning, `missing creator for mutated node` for the mlx-swift_Cmlx bundle; it is older than this change and has its own task (01M4M51GNYHZRX3NS12TVJZ12J).
    - `SKILLS_MARKETPLACE_CACHE=<new empty folder> swift test --scratch-path .build/alt --force-resolved-versions`: 901 tests in 98 suites passed, 1 known issue (the intentional `withKnownIssue` in `HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps`); XCTest 0 tests, 0 failures. EXIT=0.
    - `swift package --package-path IntegrationTests --scratch-path <fresh> show-dependencies`: EXIT=0; graph shows `otelhttp` -> `swift-otel@1.5.1 (traits: OTLPHTTP)`; IntegrationTests/Package.resolved unchanged, no grpc pin.
    - Root Package.resolved after all runs: byte-identical to the backup taken before the work; no grpc pin. Package.resolved was never edited by hand.
    - The `maintenance.lock` "skipping cache" warnings in the update logs come from the shared SwiftPM cache that parallel processes use; they are not caused by the manifest.

    Upstream: a fix exists (swiftlang/swift-package-manager#10397, PR #10547, cherry-picked to `release/6.4.1` in PR #10577, merged 2026-09-24). Thus no report draft is needed. When the toolchain is 6.4.1 or later, the root can declare swift-otel again and `OTelHTTP/` can go (the doc comments say so).

    Architecture note: no ARCHITECTURE.md exists. The new local package is a new component of the repository (a second nested package beside `IntegrationTests/`).
  timestamp: 2026-10-11T04:40:58.549540+00:00
- actor: claude-code
  id: 01m4mm7kma9v23feew7hy0n149
  text: |-
    ### implement — changed
    - evidence: 5 files — Package.swift, OTelHTTP/Package.swift (new), OTelHTTP/Sources/OTelHTTP/OTelHTTP.swift (new), Sources/acp-agent/TelemetryBootstrap.swift, README.md. Root README command 3/3 pass, no grpc pin; swift build pass; swift test 901 tests / 98 suites pass (1 intentional known issue), EXIT=0.
    - next: /review
  timestamp: 2026-10-11T04:41:12.074158+00:00
- actor: claude-code
  id: 01m4mmw8mmfh2q9t6h48aetrhy
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 85fcb0a). Counts: 0 findings, 0 confirmed, 0 refuted. 4 files reviewed: Package.swift, OTelHTTP/Package.swift, OTelHTTP/Sources/OTelHTTP/OTelHTTP.swift, Sources/acp-agent/TelemetryBootstrap.swift. Not reviewed: README.md (no validator matches it), 2 .kanban files (.reviewignore).
    - acceptance check: the README command `swift package --scratch-path "$(mktemp -d)" update swift-otel` ran with Swift 6.4 (swiftlang-6.4.0.34.1). It exited 0. Package.resolved held no `"identity" : "grpc-` pin after the update. Package.resolved was backed up before the update and restored after it (no difference).
    - next: none. The task is in done.
  timestamp: 2026-10-11T04:52:28.948714+00:00
position_column: done
position_ordinal: ffbf80
title: 'Make `swift package update` work again: SwiftPM 6.4 ignores the root swift-otel traits'
---
## Problem

`swift package update` (all packages or one package) fails in the root package each time with "exhausted attempts to resolve the dependencies graph ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf". `swift package resolve` passes.

## Cause (proved 2026-10-10, task ^85k28zk)

- A scratch package that has only `.package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.5.1", traits: ["OTLPHTTP"])` gives the same error on `swift package update` with Swift 6.4 (Xcode 27.0). `swift package resolve` passes on it.
- SwiftPM `update` does not apply the traits that the ROOT manifest sets on a dependency. It then asks for the OTLPGRPC dependencies of swift-otel (default traits), which the resolver did not fetch.
- Before FoundationModelsACPClient 24643be, the client also declared swift-otel with `OTLPHTTP` (a non-root parent), and the update could pass (sometimes after retries). 24643be removed that declaration.

## What to do

- Find a manifest form that `update` accepts and that keeps gRPC out of the graph (for example, check if a newer SwiftPM fixes it; check a form where a non-root target package declares the trait). Do not edit Package.resolved by hand.
- Add a check (or a documented command) that proves `swift package update` passes.
- Report the SwiftPM defect upstream if no fix exists.

## Acceptance

- [x] `swift package --scratch-path <path> update <one package>` passes in the root package.
- [x] Package.resolved holds no grpc pin after the update.