---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4mwx17vrbxvf6z9at64f7cn
  text: |-
    Research result (2026-10-11).

    Cause: a defect in the Swift Build engine (the default SwiftPM 6.4 build system), with the SwiftPM PIF generator. It is not a defect in mlx-swift or in our manifest.

    Chain of events:
    1. The Cmlx target of mlx-swift declares no resources. SwiftPM finds the `.metal` files in `Source/Cmlx/mlx-generated/metal` and processes them as resources by default. Thus SwiftPM makes the resource bundle target `mlx-swift_Cmlx`.
    2. The SwiftPM PIF builder (`Sources/SwiftBuildSupport/PackagePIFProjectBuilder.swift`, comment "Metal source code needs to be added to the source build phase") puts each processed `.metal` file in the Sources build phase of the resource bundle target. The same builder sets `EXECUTABLE_NAME = ""` for that target.
    3. Swift Build `TaskProducerContext.willProduceBinary` (`SWBTaskConstruction/TaskProducers/TaskProducer.swift`) returns true when the Sources phase is not empty. It does not ignore Metal files.
    4. Thus `CodesignToolSpec.constructCodesignTasks` (`SWBCore/SpecImplementations/Tools/CodeSign.swift`) adds `TARGET_BUILD_DIR/EXECUTABLE_PATH` as a mutated input and output of the CodeSign task. With an empty executable name, that path is `mlx-swift_Cmlx.bundle/Contents/MacOS`.
    5. No task makes that path (the bundle has no binary). `BuildDescription.swift` in `SWBTaskExecution` then writes "missing creator for mutated node".

    Evidence:
    - Package graph: FoundationModelsRouter -> mlx-swift-lm (swissarmyhammer fork, branch `stable`, d609e75) -> mlx-swift `.upToNextMinor(from: "0.32.3")`. Package.resolved pins mlx-swift 0.32.3 (19601207). 0.32.3 is the newest tag. mlx-swift `main` (1e61d9c) has no change to Package.swift after 0.32.3.
    - `.build/alt/out/Intermediates.noindex/XCBuildData/<newest>.xcbuilddata/manifest.json`: the node `.../mlx-swift_Cmlx.bundle/Contents/MacOS` has `is-mutated: true`, and no command makes it. The task store shows the CodeSign task of `PACKAGE-RESOURCE:Cmlx` with that path as an output. The bundle has `Contents/Resources/default.metallib`, `Info.plist` and `_CodeSignature`, and no `Contents/MacOS`. The other resource bundles (TreeSitter, Crypto, NIOSSL, Hub) have no Metal sources and do not get the warning.
    - Minimal reproduction in the scratchpad (`metalrepro`): one Swift target with one `add.metal` file and no resource declaration. `swift build` (Swift 6.4.0-dev, Xcode 27.0 27A266a, default build system swiftbuild) writes the same warning for `metalrepro_Kern.bundle/Contents/MacOS`. A control target with a `.copy` resource gives no warning.
    - `--build-system native` gives no warning, but it does not compile the `.metal` file at all ("found 1 file(s) which are unhandled"). It is deprecated. Thus it is not a fix: MLX needs `default.metallib`.
    - The defect is present in swift-build main 2187330 (2026-10-09) and swift-package-manager main 5546f44 (2026-10-08). Web search found no known upstream issue. A similar report exists for Xcode 10: a resource bundle target that compiled a Core Data model got the same warning (https://developer.apple.com/forums/thread/107819).

    Effect: the warning only. The build, the code signature and the metallib are correct. The tests pass.

    Why it cannot be removed here: our manifest does not declare mlx-swift and has no setting that changes this behavior. A manifest change in mlx-swift that keeps the `.metal` processing keeps the warning. A local override, a checkout edit or a Package.resolved edit is not permitted.

    Proposed fix and where it belongs:
    - Primary, in swift-build: `willProduceBinary` must not count Metal (and other non-object-producing) sources as binary-producing, or `constructCodesignTasks` must not add the executable path when `EXECUTABLE_NAME` is empty. This removes the warning for every package with Metal resources.
    - Alternative, in swift-package-manager: give the Metal-only resource bundle target a setting or a build phase so that Swift Build does not expect a binary.
    - Possible mlx-swift change (not recommended): precompile `default.metallib` with a build tool plugin and declare it as a `.copy` resource (Apple TN3133). This is a large change in mlx-swift for a warning only.
    - What removes the warning for us: a SwiftPM / Xcode toolchain that has a Swift Build release with the fix. No mlx-swift release removes it now.

    Nothing filed on an external service. No file changed.
  timestamp: 2026-10-11T07:12:42.747853+00:00
- actor: claude-code
  id: 01m4mwxcm56e93nxwpctk7h30g
  text: |-
    ### implement — stuck
    - evidence: no file changed. Cause is in swift-build `willProduceBinary` / `constructCodesignTasks` with SwiftPM PIF Metal handling; reproduced with a one-file Metal package (scratchpad `metalrepro`); manifest.json node `mlx-swift_Cmlx.bundle/Contents/MacOS` is `is-mutated` with no creator.
    - next: a person decides on an upstream report to swift-build. Nothing in this repository can remove the warning.
  timestamp: 2026-10-11T07:12:54.405018+00:00
- actor: claude-code
  id: 01m4mwyan3cst0t1rd5skkq63a
  text: |-
    step: review
    outcome: clean
    evidence: no code change. The task asks to remove the warning or to record why it cannot be removed here. The cause is recorded: Swift Build (SwiftPM 6.4) adds the empty executable path of a resource bundle with only Metal sources to its CodeSign task. A minimal repro is in the scratchpad (`metalrepro`). No manifest in this repo controls it. An upstream report to swift-build is a decision for the user, and it is not part of this task.
    task: ^tvjz12j
  timestamp: 2026-10-11T07:13:25.155084+00:00
position_column: done
position_ordinal: ffc280
title: 'Each swift build writes "warning: missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
## State now

Each `swift test` build of the root package and of `IntegrationTests` (with `--scratch-path .build/alt` or `IntegrationTests/.build/alt`) writes this SwiftPM build-system warning:

`warning: missing creator for mutated node: ('<scratch>/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

It was in the log of a run on 2026-10-10 before the change of task ^8zjqm5d, so that change did not cause it. The tests pass.

## Do

Find the cause (the resource bundle of the `Cmlx` target of mlx-swift, or the SwiftPM version), and remove the warning, or record why it cannot be removed here.

## Result (2026-10-11)

- [x] Cause found: a Swift Build defect. A resource bundle target with Metal sources gets a CodeSign task that mutates `Contents/MacOS` (the empty executable path), and no task makes that path. Full evidence is in the comments.
- [x] A minimal package with one `.metal` file shows the same warning with Swift 6.4.0-dev / Xcode 27.0.
- [ ] Decision for a person: the warning cannot be removed in this repository. The fix belongs in swift-build (or the SwiftPM PIF builder). A toolchain with that fix removes it. No mlx-swift release removes it now.

#tests