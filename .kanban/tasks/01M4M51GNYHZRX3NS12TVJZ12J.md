---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: 'Each swift build writes "warning: missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
## State now

Each `swift test` build of the root package and of `IntegrationTests` (with `--scratch-path .build/alt` or `IntegrationTests/.build/alt`) writes this SwiftPM build-system warning:

`warning: missing creator for mutated node: ('<scratch>/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

It was in the log of a run on 2026-10-10 before the change of task ^8zjqm5d, so that change did not cause it. The tests pass.

## Do

Find the cause (the resource bundle of the `Cmlx` target of mlx-swift, or the SwiftPM version), and remove the warning, or record why it cannot be removed here.

#tests