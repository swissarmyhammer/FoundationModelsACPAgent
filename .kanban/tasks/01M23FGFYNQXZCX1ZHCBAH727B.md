---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: CLIProcessTests still expects doctor to be a stub, and the tier-3 pin lags the root package
---
## The defect

Two faults stand in the tier-3 package. Both were invisible, because the
package did not build.

### 1. The build

`swift test --package-path IntegrationTests` failed to compile:

```
Sources/acp-agent/ProgressReporter.swift:87:34: error: cannot find type 'SlotProgress' in scope
```

`IntegrationTests/Package.resolved` pinned FoundationModelsRouter at
`bd8b6ff0`, and the root `Package.resolved` pins `d469aa0a`. The newer
revision carries the public `SlotProgress` type that card ^mnww4p1 added.
A local `swift package --package-path IntegrationTests update
foundationmodelsrouter` fixed the build. The pin file is ignored by git, so
CI resolves fresh and does not show this. A developer with an old checkout
does.

### 2. The stale test

With the package building again, one case fails:

```
CLIProcessTests.aStubSubcommandExitsOneAndSaysSoOnStderr
  expected exit 1, got the doctor report
  expected stderr to contain "is not implemented yet"
```

`Self.stubSubcommand` is `"doctor"`. The `doctor` subcommand was
implemented by card ^p3h7ncn, and it now runs its checks and writes its
report. No `acp-agent` subcommand is a stub any more, so the case measures
nothing.

The file has not changed since commit `9c51ba1`, which is before the doctor
card landed. That is the proof the suite has not run since.

## The fix

- [ ] Delete `aStubSubcommandExitsOneAndSaysSoOnStderr`, and the
      `stubSubcommand` and `notImplementedMarker` constants it alone
      reads. There is no stub subcommand left to measure.
- [ ] Decide whether a tier-3 case for `acp-agent doctor` belongs in that
      suite instead, and add it when it does.
- [ ] Find out why the tier-3 package is not run. Run it in CI, or say on
      the card why it is not run.

## Done when

- [ ] `swift test --package-path IntegrationTests` builds from a clean
      checkout.
- [ ] Every case of `CLIProcessTests` passes.
