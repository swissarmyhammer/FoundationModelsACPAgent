---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7vrmxrb291ekjkjfc27wy0q
  text: |-
    Package update: Extras resolves at main 5660d0d, Router resolves at main 95c2141. Package.resolved is gitignored, so no file change.

    The importer now gives `sourceTitle: source.metadata.title` to the provenance. `source` is the scanned `LocatedSessionMetadata`. The `row(of:)` function of `importable(_:)` uses the same `metadata.title`, so the provenance and the list show the same title.

    TDD: the provenance test (default fixture title "Title A", now the named constant `ImportFixture.sourceTitle`) failed first with sourceTitle nil. A new test imports a source with no title and expects nil.

    The push item is open. The coordinator commits and pushes, then sends the sha to testudoapp-9a.
  timestamp: 2026-11-20T06:00:09.227198+00:00
- actor: claude-code
  id: 01m7vrn0013d0n54bwb78zawye
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift, Tests/FoundationModelsACPAgentTests/AgentSessionImporterTests.swift
    - next: coordinator commits and pushes, then sends the sha to testudoapp-9a

    ### test — green
    - evidence: swift build --build-tests "Build complete!" with 0 project warnings; timeout 1800 swift test --skip-build: 2730 tests in 286 suites passed, 0 failures (1 known issue: a withKnownIssue in HarnessSmokeTests that existed before)
    - next: review
  timestamp: 2026-11-20T06:00:11.521770+00:00
- actor: claude-code
  id: 01m7vry1h6ftenvb5688nfs9q0
  text: |-
    ### review — clean
    - evidence: `review sha 95289cc~1..95289cc` (HEAD~1..HEAD); 2 files reviewed (AgentSessionImporter.swift, AgentSessionImporterTests.swift); 0 findings (0 confirmed, 0 refuted). The card has no earlier review findings. The item "Push to origin/main and send the sha" is a task item, not a review finding.
    - next: Push to origin/main and send the sha to the TestudoApp session (testudoapp-9a).
  timestamp: 2026-11-20T06:05:08.006633+00:00
position_column: done
position_ordinal: ffffffb480
title: 'D209: the importer sets sourceTitle in the import provenance'
---
TestudoApp asked for this on 2026-11-20. Extras 5660d0d added the optional `sourceTitle: String?` to `SessionImportProvenance`. Its init argument comes after `sourcePath`, and the default is nil. Router changes its recorded provenance to keep the field.

## Change
- [x] Move the Extras pin to 5660d0d or later (`swift package update FoundationModelsExtras`; also Router if its head keeps the field). Extras 5660d0d, Router 95c2141; Package.resolved is gitignored.
- [x] At `Sources/FoundationModelsACPAgent/Import/AgentSessionImporter.swift` (about line 221), give `sourceTitle:` the title from the source reader: the same title that `importableSessions` shows.
- [x] A test proves that the provenance of an import holds the source title, and that a source with no title gives nil.
- [x] Push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). Code 95289cc, pushed with the card commit. #d209 #import