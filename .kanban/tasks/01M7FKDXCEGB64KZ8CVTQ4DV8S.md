---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7mn58kvk4m5kkmvkbvhampv
  text: |-
    Research:
    - The resolver type in ModelResolver.swift is `SystemModelResolver` (the card says `HubModelResolver`). Its internal `init(source:cacheDirectory:)` takes a `MetadataSource`, thus a unit test can give a stub tree.
    - The library target links FoundationModelsExtras, and `GGUFFileSet.select(from:under:)` is public. The fix reuses it directly.
    - Router `RepoMetadata.ggufFileSet(in:under:name:)` is internal to Router, so this package cannot call it. It scopes the paths to `path` or `path/` before format detection; only a GGUF model loads from a path.
    - Decision for a path that `GGUFFileSet.select` refuses (no GGUF model, ambiguous, incomplete split set): price the files under the path (the same scoping as Router), because a doctor lookup never throws. A test covers this case.
  timestamp: 2026-11-17T11:44:29.307345+00:00
- actor: claude-code
  id: 01m7mnsctmxey9h792pb0c0tct
  text: |-
    Implementation landed.
    - RED: new suite Tests/FoundationModelsACPAgentTests/Doctor/SystemModelResolverTests.swift. The GGUF file test got 7010 bytes (whole tree), expected 1000. The folder test also failed. The no-path test passed, because it pins the current behavior.
    - GREEN: `SystemModelResolver.missingBytes(of:under:repo:)` now prices only `selectedEntries(of:under:)`. With no path, the whole tree. With a path, `GGUFFileSet.select(from:under:)` of Extras (shards and projector). When select refuses, the path and the files under it.
    - `swift build --build-tests`: Build complete!. `swift test --skip-build --filter "SystemModelResolverTests|ProfileDoctorTests|ModelCacheDirectoryTests"`: 27 tests in 3 suites passed.
  timestamp: 2026-11-17T11:55:28.980243+00:00
- actor: claude-code
  id: 01m7mnssktnn3n1zgn6w2dz0sm
  text: |-
    ### implement — changed
    - evidence: commit d6d66bd in worktree agent-a37428074a3f6e655. 2 files: Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift, Tests/FoundationModelsACPAgentTests/Doctor/SystemModelResolverTests.swift. 27 tests in 3 suites passed (SystemModelResolverTests, ProfileDoctorTests, ModelCacheDirectoryTests).
    - note: the kanban tool writes to the board of the main checkout, so the commit holds no .kanban changes.
    - next: review
  timestamp: 2026-11-17T11:55:42.074464+00:00
- actor: claude-code
  id: 01m7mp6np4jbntvdz4hw85r7fd
  text: |-
    ### review — clean
    - evidence: review sha 8fd614a~1..8fd614a, 7 validators, 0 findings. Full suite on main: 2223 tests pass (1 known issue).
    - next: done.
  timestamp: 2026-11-17T12:02:44.036991+00:00
position_column: done
position_ordinal: fffffb80
title: 'doctor: price a GGUF reference by its file path, not the whole repository'
---
`HubModelResolver.missingBytes` (Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift) sums every file of the repository tree that no snapshot holds. A reference that names one GGUF file inside its repository (`owner/name/file.gguf@rev`, such as Router's default decision candidate `h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b…`) downloads only that file (and its split shards / projector), but the doctor prices every quantization in the repository. Since the decision slot joined `ProfileDoctor.slotReferences`, the default profile's disk row overstates the next download, and the "on disk" row can say a cached decision file still downloads (the other quants are not on disk).

Fix: scope the priced entries to the reference's `ModelRef.path` the way Router's `GGUFRepoMetadata.ggufFileSet(in:under:name:)` / Extras `GGUFFileSet.select(from:under:)` choose the files of a GGUF model. Pass the reference path into `missingBytes`, and check the snapshot only for those files.

- [x] Failing unit test first (StubModelResolver is not enough: test `HubModelResolver` over a tree source with two GGUF quants and a path that names one; expect only that file's bytes)
- [x] Scope `missingBytes` to the files the path selects
- [x] A reference with no path keeps pricing the whole tree #doctor