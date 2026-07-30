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
Plan.md §1 (composition spine: `config → ProfileDefinition → Router.resolve → resident profile`), §2.1 (the name's third consumer), §2.2 (layer-1 defaults). Create `Sources/FoundationModelsACPAgent/Configuration/ProfileResolution.swift`:

- Map the decoded `profile` config section (standard/flash/embedding slots) to Router's `ProfileDefinition`.
- **`profile.name` falls back to the dotfolder `<name>` when unset** — one of exactly three consumers of the name (§2.1); an explicit configured name wins.
- Resolve via `Router.resolve` to a resident profile at agent construction; the in-code default configuration selects a coding-model profile that operates correctly on a 16 GB machine (§2.2 layer 1).
- Expose the resident profile to session creation (the `standard`/`flash` slots the config-options task later surfaces).
- Tests inject a scripted `ModelLoader` — no real model resolution, no download.

- [ ] `profile` section → `ProfileDefinition` mapping
- [ ] `profile.name` → `<name>` fallback
- [ ] Resolution at agent construction via `Router.resolve`
- [ ] Resident profile reachable by session creation

## Acceptance Criteria
- [ ] With no `profile.name` configured, the resolved profile's name equals the dotfolder name; with one configured, the configured name wins
- [ ] Configured slot values reach the constructed `ProfileDefinition` (asserted field by field)
- [ ] Agent construction with the default configuration resolves without touching the network (scripted loader observed)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/ProfileResolutionTests.swift` — mapping matrix + fallback + construction path with the injected loader
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.