---
assignees:
- claude-code
depends_on:
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
- 01KYSV6BNDNMQ9T6RKFQ3P1ZD2
- 01KYSV6QHJ631K7T7FRF4B8338
- 01KYSV76CBJV66C92Z0EM2S73K
- 01KYSV83KNKXPSMJMQX5TFSPGC
- 01KYSVR3HG5TB7G8DA7NZ60Y96
- 01KYSV93N6D4RWYQ7XMCHQ21GW
position_column: todo
position_ordinal: '8980'
title: 'session/new: compose config, instructions, tools into a root Router session'
---
## What
Plan.md §7.1 (+§4.2 identity). In `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift` (+ additions to `RoutedACPAgent.swift`):

- `session/new(cwd, mcpServers, additionalDirectories)`: require absolute `cwd` (error otherwise). Per session: resolve the cwd config layer (ConfigurationLoader), assemble instructions (InstructionsAssembler), await MCP connection (MCPComposition), construct the roster (`ToolCatalog.builtin(context:)`), then `router.makeSession(workingDirectory:tools:instructions:budget:compactionPrompt:recordingRoot:)` on the resident profile (ProfileResolution) with the transcript root from TranscriptLocation.
- **The ACP `sessionId` IS the root Router session's ULID, serialized** — no mapping table (§4.2).
- Multiple concurrent sessions from the start: sessions keyed by `sessionId` in an actor-held table; each session carries its own config, instructions, confinement, transcript dir (§7.1).
- One prompt per session at a time: track per-session idle/busy; a `session/prompt` while not idle → client error, not a queue entry (§7.1) — enforced here, exercised in the prompt task.
- Register the cwd in `ProjectRegistry` at session/new. **Do NOT append the `SessionIndex` record here** — per §9's zero-turn rule ("has a persisted transcript is the listability test"), the index record is written at first recorded activity, by the prompt-turn task, together with the title. This is the chosen design; the store's directory-less-entry exclusion is a safety net, not the mechanism.
- `NewSessionResponse` carries `configOptions` (empty array placeholder until the config-options task fills it — leave a marked TODO).

- [ ] Absolute-cwd validation
- [ ] Per-session composition pipeline
- [ ] sessionId = Router ULID
- [ ] Concurrent session table + idle/busy tracking
- [ ] Registry write at new; index write deferred to first activity

## Acceptance Criteria
- [ ] `session/new` on a temp dir returns a sessionId that parses as a ULID and matches the Router session directory name on disk
- [ ] Relative `cwd` → error
- [ ] Two concurrent sessions in two temp repos load different project-layer config values (assert via a config-visible behavior, e.g. shell disabled in one)
- [ ] After `session/new` alone: `projects.jsonl` has the cwd and `sessions.jsonl` has NO record for the session (zero-turn rule)

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift` — on the test harness (RecordingClient + scripted ModelLoader); temp-dir repos
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.