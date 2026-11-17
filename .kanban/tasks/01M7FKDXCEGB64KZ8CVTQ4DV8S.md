---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: 'doctor: price a GGUF reference by its file path, not the whole repository'
---
`HubModelResolver.missingBytes` (Sources/FoundationModelsACPAgent/Doctor/ModelResolver.swift) sums every file of the repository tree that no snapshot holds. A reference that names one GGUF file inside its repository (`owner/name/file.gguf@rev`, such as Router's default decision candidate `h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b…`) downloads only that file (and its split shards / projector), but the doctor prices every quantization in the repository. Since the decision slot joined `ProfileDoctor.slotReferences`, the default profile's disk row overstates the next download, and the "on disk" row can say a cached decision file still downloads (the other quants are not on disk).

Fix: scope the priced entries to the reference's `ModelRef.path` the way Router's `GGUFRepoMetadata.ggufFileSet(in:under:name:)` / Extras `GGUFFileSet.select(from:under:)` choose the files of a GGUF model. Pass the reference path into `missingBytes`, and check the snapshot only for those files.

- [ ] Failing unit test first (StubModelResolver is not enough: test `HubModelResolver` over a tree source with two GGUF quants and a path that names one; expect only that file's bytes)
- [ ] Scope `missingBytes` to the files the path selects
- [ ] A reference with no path keeps pricing the whole tree #doctor