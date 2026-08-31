---
assignees:
- claude-code
depends_on:
- 01KYSV5606NB4K39ZXQYPBH0A9
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
position_column: todo
position_ordinal: 9b80
title: 'Profile resolution: ProfileDefinition from config, name fallback, resident profile'
---
## What
Plan.md §1 (the composition spine `config → ProfileDefinition → Router.resolve → resident profile`), §2.1 (the name's third consumer), §2.2 (layer-1 defaults).

Create `Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift`.

Map the decoded `profile` config section to Router's `ProfileDefinition`. **The initializer is:**

```swift
ProfileDefinition(name: String,
                  description: String,
                  standard: [ModelRef],
                  flash: [ModelRef],
                  embedding: [ModelRef],
                  context: Int? = 8192)
```

Note these facts:
- **Each slot is a candidate LIST, not one model.** `standard`, `flash` and `embedding` are `[ModelRef]`. Router measures the real RAM and GPU budget and picks the biggest candidate that fits each slot.
- **`description` is required.** Supply one.
- `context: nil` opts into ladder derivation from each candidate's native maximum context. The default is 8192.
- **`ModelRef` can only be built from a string literal or by decoding.** Its `repo`, `revision`, `init(repo:revision:)` and `init(_ string:)` are all internal. Read a value back only as `stringValue`. The separator is `@`, as in `"org/repo@rev"`. So the config decode path must produce `ModelRef` through `Codable`, never through a runtime string initializer.

Resolve with **`Router.resolve(profile:reporting:)`**. The label is `profile:`. Router's README shows `router.resolve(coding, reporting:)`, which does not compile; upstream carded that fix.

- `profile.name` falls back to the dotfolder `<name>` when it is not set. This is one of exactly three consumers of the name (§2.1). A configured name wins.
- Resolve to a resident profile when the agent is constructed. The in-code default configuration selects a coding profile that works on a 16 GB machine (§2.2 layer 1).
- **Hold the resident profile strongly for the life of the agent.** `LanguageModelProfile.init` is `package`, so `Router.resolve` is the only way to get one. Residency is pooled and reference counted. Each `RoutedModel` holds its owning profile weakly, and every public `makeSession` calls `preconditionFailure` if the profile was already released. Only the vended session retains it.
- Tests inject a scripted `ModelLoader`. Do no real resolution and no download.

**Error handling, corrected.** An earlier draft said no Router error type can be caught. That is wrong. `ResolutionFailure` — the error `resolve` throws when no candidate trio fits — IS internal, so catch `any Error` on the resolve path and report its message. But Router does publish catchable error types, and later tasks use them: `GenerationError`, `GuidedRequestError`, `ToolMountError`, `DiscoveryPrimingFailure`, and the `LostRunError` protocol. `LostRunError` matters most: a tool error that conforms makes the run settle `.lost`.

- [ ] `profile` section → `ProfileDefinition` mapping, with candidate lists
- [ ] `profile.name` → `<name>` fallback
- [ ] Resolution through `Router.resolve(profile:reporting:)` at construction
- [ ] The resident profile is held strongly and reaches session creation
- [ ] The resolve path catches `any Error` and reports the message

## Acceptance Criteria
- [ ] With no `profile.name` configured, the resolved profile name equals the dotfolder name; a configured name wins
- [ ] A config listing three `standard` candidates produces a `ProfileDefinition` with three `ModelRef` values, asserted by `stringValue`
- [ ] `context` omitted from config produces `nil`, not 8192, so the ladder applies
- [ ] Agent construction with the default configuration resolves and touches no network, observed through the scripted loader
- [ ] A scripted resolution failure surfaces as a reported error with a readable message
- [ ] Two sequential sessions both construct, which proves the profile stayed alive and no `preconditionFailure` fired

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift` — the mapping matrix, the fallback, the failure path, and the construction path with the injected loader
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.