---
position_column: todo
position_ordinal: 9b80
title: 'The agent is the only judge of cwd: validate session/list too, and name the field in the error'
---
## What

`FoundationModelsACP` will stop refusing relative paths at decode (card in that package: "AbsolutePath: mirror the schema, and stop refusing relative paths at decode"). After that, `SessionSetup.validatedWorkingDirectory(path:)` is the only refusal of a relative `cwd`. That is the protocol's intent: the agent owns the file system, and the agent answers invalid params. Three gaps remain.

- [ ] `Sources/FoundationModelsACPAgent/Agent/SessionList.swift:32-34`: `params.cwd` goes straight into `URL(fileURLWithPath:)`. A relative filter keys off the process cwd. Route it through `validatedWorkingDirectory(path:)`, the same as `newSession` and `resumeSession`.
- [ ] `SessionSetup.swift:137`: the error is a bare `.invalidParams`. Add `data: {"field": "cwd", "reason": "must be absolute"}`. This is the shape `FoundationModelsACP` pins in `RequestErrorTests.theWireFormRoundTrips`. A person then reads which field failed, and why. Give a relative `additionalDirectories` entry the same `data` with its own field name.
- [ ] `SessionSetup.swift:135-136`: the doc says "the same JSON-RPC error the wire decode of `AbsolutePath` gives". After the wire change there is no such decode error. Correct the doc.
- [ ] `SessionList.swift:128`: `guard let cwd = AbsolutePath(rawValue: record.cwd)` stops compiling with a non-failable init. The same applies to `EventProjection.swift` and about 30 test sites. Find them with `rg -n 'AbsolutePath\(rawValue:' Sources Tests`.

## Acceptance Criteria

- [ ] `session/new`, `session/resume` and `session/list` with a relative `cwd` each answer `-32602` with `data.field == "cwd"` and `data.reason == "must be absolute"`, and open no session.
- [ ] `swift test` is green: 0 failures, 0 warnings.

## Tests

- [ ] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift`, `aRelativeCwdOverTheWireAnswersInvalidParams`: assert `data.field` and `data.reason`, not `code` alone. Before the wire change this error comes from the decoder and has no `data`. After it, the error comes from the agent. The assertion on `data` is what proves the check moved.
- [ ] New test in `SessionListTests.swift`: a relative `cwd` filter answers invalid params with the same `data`.
- [ ] New test in `SessionSetupTests.swift`: a relative `additionalDirectories` entry answers `data.field == "additionalDirectories"`.

## Depends on

The `FoundationModelsACP` card "AbsolutePath: mirror the schema, and stop refusing relative paths at decode", pushed and re-resolved in `Package.resolved`.

## Workflow

- Use `/tdd`. Write the failing tests first.