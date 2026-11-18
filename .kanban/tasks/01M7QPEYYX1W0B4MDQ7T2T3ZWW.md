---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qpfbmnyfq18ksyt0s5c5t3
  text: |-
    Router ROUTER-13 field names are final (2026-11-18, Router task ^h27ffj0, not on origin/main yet; the Router sends the sha when it lands):
    - `ProfileFitEstimate.contextTokens: Int?`: the window of the chosen fit; nil when the profile does not fit.
    - `ProfileFitEstimate.defaultMinimumContextTokens = 32_768` (public static).
    - `Router.estimateFit(of:minimumContextTokens:)`, with that default. `estimateFit(of:)` still compiles.
    - A largest fitting window under the minimum gives `fits == false`, `contextTokens == nil`, and a `failure` that names both windows. When the native window is under the minimum, the minimum is the native window.
    - `resolve(profile:)` does not change.
    Write the stub fit source with these names.
  timestamp: 2026-11-18T16:05:11.957798+00:00
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: todo
position_ordinal: 8b80
title: 'ACPA-23 (D203): the default profile is the largest that fits; contextTokens and target memory on the models endpoint'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, parts 2 and 5.

## Dependencies

- ^56r9vp9 (the three bundled profiles). Also do it after the unknown-name task, because both use the fallback function.
- FoundationModelsRouter ROUTER-13 on `main` (`router-brief.md`): the minimum window (32K) in `estimateFit(of:)`, and `contextTokens` in `ProfileFitEstimate`. Not on this board. You can start with a stub fit source, and connect Router when it is on `main`.

## Current state

- The default name is static: `AgentConfiguration.profile.name = BundledProfiles.defaultName` (`Configuration/AgentConfiguration.swift:302`). No fit decides it.
- The `models` endpoint gives the fit of each profile with `ProfileFitReport` (`Models/ProfileFit.swift:9-46`): `fits`, `requiredBytes`, `budgetBytes` and `failure`, from `Router.estimateFit(of:)` (`:62-68`). The `ModelProfile` GraphQL type is at `Models/ModelsGraph.swift:472-492` and `Models/ModelsGraphTypes.swift:246`. It has no window and no target memory.

## Change

1. When no layer sets `profile`, the agent uses the largest bundled profile, in the order of `BundledProfiles.names`, whose fit estimate says `fits` (the fit includes the minimum window of ROUTER-13). When no fit can be read (no Metal device, the estimate fails or is cancelled), the agent uses `small`. The fallback of an unknown name is the same choice.
2. The fit read is async and `resolvingProfile` is sync. Do the choice where the async load is (`SessionSetup.load`, or the settings store). Keep one function that both the agent and the `acp-agent` CLI call.
3. `ProfileFitReport` and the `ModelProfile` type get `contextTokens: Int` (nullable): the window of the fit, from `ProfileFitEstimate.contextTokens`.
4. `ModelProfile` gets the target memory of a bundled profile (for example `targetMemory: String`: "48 GB or more", "32 GB", "16 GB or 24 GB"). It is `null` for a profile file of the user or the project.
5. README: describe the default by fit.
6. When the field names are on `main`, tell the TestudoApp session (testudoapp-9a) the names.

## Tests

- With a stub fit source where only `small` fits, no `profile` key selects `small`.
- Where `medium` and `small` fit, it selects `medium`.
- Where the source fails, it selects `small`.
- The CLI uses the same choice.
- The endpoint gives `contextTokens` and the target memory of each bundled profile, and `null` target memory for a user profile file.

When this lands, push to origin/main and send the sha and the field names to the TestudoApp session (testudoapp-9a). #d203 #profiles #acpa-23