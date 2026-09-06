---
comments:
- actor: claude-code
  id: 01m1w2qt6ay4a98qec45dwqyry
  text: |
    ### research

    Dependency check: the upstream card landed. `FoundationModelsACP` commit `f6e2b6e` ("fix(core): make AbsolutePath mirror the schema and accept any string at decode") is on `main`. `Package.resolved` still pinned the older `9ab9f64`, so this card re-resolved the pin to `3b0a4fd`. `AbsolutePath` now has a non-failable `init(rawValue:)` and refuses nothing at decode.

    What the resolved package gives:
    - `NewSessionRequest.additionalDirectories` decodes with `forgivingDecodeArrayIfPresent`. No entry can fail to decode now, so no entry is dropped on the way in. The agent is the only judge.
    - `RequestErrorTests.theWireFormRoundTrips` pins the data shape `{"field":"cwd","reason":"must be absolute"}`.

    Sites this card must touch:
    - `SessionSetup.swift:137` `validatedWorkingDirectory(path:)` throws a bare `.invalidParams`.
    - `SessionSetup.swift:157` `additionalRoots(fromPaths:)` skips a relative entry with a log. That skip mirrored a wire decode that no longer drops anything, so a relative entry would now be dropped silently. It must refuse.
    - `SessionList.swift:32-34` puts `params.cwd` straight into `URL(fileURLWithPath:)`.
    - `SessionList.swift:128,135` and `EventProjection.swift:580-581` use the failable init, which no longer compiles.
    - Test sites that use `try #require(AbsolutePath(rawValue:))` no longer compile.

    Design:
    - One door for the absolute rule in `SessionSetup.swift`: `isAbsolute(_:)`, plus `AbsolutePath.init?(absolute:)` for every "drop what is not absolute" site (`SessionList`, `EventProjection`).
    - `SessionSetup.PathField` names the field (`cwd`, `additionalDirectories`), and `RequestError.relativePath(field:)` builds the pinned `data` shape.
    - `MultiRootConfinementTests` holds two tests that assert the old skip rule. The card changes that contract, so both are rewritten to assert the refusal. `RawWireClient` in that file exists only because the typed API could not carry a relative entry; that reason is gone, so it goes with them.
  timestamp: 2026-09-06T19:22:18.698846+00:00
position_column: doing
position_ordinal: '80'
title: 'The agent is the only judge of cwd: validate session/list too, and name the field in the error'
---
## What

`FoundationModelsACP` will stop refusing relative paths at decode (card in that package: "AbsolutePath: mirror the schema, and stop refusing relative paths at decode"). After that, `SessionSetup.validatedWorkingDirectory(path:)` is the only refusal of a relative `cwd`. That is the protocol's intent: the agent owns the file system, and the agent answers invalid params. Three gaps remain.

- [x] `Sources/FoundationModelsACPAgent/Agent/SessionList.swift:32-34`: `params.cwd` goes straight into `URL(fileURLWithPath:)`. A relative filter keys off the process cwd. Route it through `validatedWorkingDirectory(path:)`, the same as `newSession` and `resumeSession`.
- [x] `SessionSetup.swift:137`: the error is a bare `.invalidParams`. Add `data: {"field": "cwd", "reason": "must be absolute"}`. This is the shape `FoundationModelsACP` pins in `RequestErrorTests.theWireFormRoundTrips`. A person then reads which field failed, and why. Give a relative `additionalDirectories` entry the same `data` with its own field name.
- [x] `SessionSetup.swift:135-136`: the doc says "the same JSON-RPC error the wire decode of `AbsolutePath` gives". After the wire change there is no such decode error. Correct the doc.
- [x] `SessionList.swift:128`: `guard let cwd = AbsolutePath(rawValue: record.cwd)` stops compiling with a non-failable init. The same applies to `EventProjection.swift` and about 30 test sites. Find them with `rg -n 'AbsolutePath\(rawValue:' Sources Tests`.

## Acceptance Criteria

- [x] `session/new`, `session/resume` and `session/list` with a relative `cwd` each answer `-32602` with `data.field == "cwd"` and `data.reason == "must be absolute"`, and open no session.
- [x] `swift test` is green: 0 failures, 0 warnings.

## Tests

- [x] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift`, `aRelativeCwdOverTheWireAnswersInvalidParams`: assert `data.field` and `data.reason`, not `code` alone. Before the wire change this error comes from the decoder and has no `data`. After it, the error comes from the agent. The assertion on `data` is what proves the check moved.
- [x] New test in `SessionListTests.swift`: a relative `cwd` filter answers invalid params with the same `data`.
- [x] New test in `SessionSetupTests.swift`: a relative `additionalDirectories` entry answers `data.field == "additionalDirectories"`.

## Depends on

The `FoundationModelsACP` card "AbsolutePath: mirror the schema, and stop refusing relative paths at decode", pushed and re-resolved in `Package.resolved`. Landed as `f6e2b6e`; both packages now resolve `main` at `3b0a4fd`. `Package.resolved` is gitignored in this repository and the pin is the `main` branch, so the re-resolve is a local step and no file is committed for it.

## Workflow

- Use `/tdd`. Write the failing tests first.
