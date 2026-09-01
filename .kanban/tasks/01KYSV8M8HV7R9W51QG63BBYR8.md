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
Plan.md §7.1 (and §4.2 identity). Work in `Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift`, plus additions to `RoutedACPAgent.swift`.

`session/new(cwd, mcpServers, additionalDirectories)`:

- Require an absolute `cwd`. Error if it is relative.
- Per session: resolve the cwd config layer (ConfigurationLoader), assemble the instructions (InstructionsAssembler), connect the MCP servers (MCPComposition), then build the roster with `ToolCatalog.sessionTools(context:)`.

**Make the session from the profile, not from the router.** The old task text said `router.makeSession(...)`. That call does not exist. `Router` has only three public members: `id`, `init` and `resolve(profile:reporting:)`. The session comes from the profile's model handle:

```swift
profile.standard.makeSession(
    instructions: assembled,
    workingDirectory: cwd,
    recordingRoot: transcriptRoot,
    tools: sessionTools,
    budget: budget,
    compactionPrompt: .default)
```

`RoutedLLM.makeSession(configuration: SessionConfiguration)` is the other door. `SessionConfiguration` carries the same fields plus `grammar`. Leave `grammar` nil; a non-nil grammar vends a guided session.

**Leave `agentSpawn:` at its default `nil`.** Agents are not implemented yet. A later iteration adds them as a Multitool code-mode background capability (plan.md §11.3). Only that capability makes a spawned session, and it does so from inside a tool call, never from `session/new`.

**Hold the profile for the life of the agent.** A `RoutedModel` holds its owning profile weakly. Every public `makeSession` traps with `preconditionFailure` if the profile was released. Only the vended session retains it. So the agent must keep a strong reference to the resident profile.

Other rules:
- **The ACP `sessionId` IS the root Router session's ULID, serialized.** No mapping table (§4.2). Parse a ULID string with the library initializer `ULID(ulidString:)`. Router's own `ULID.init?(_ string:)` is internal.
- Support many sessions at once from the start. Keep sessions in an actor-held table keyed by `sessionId`. Each session carries its own config, instructions, confinement and transcript directory.
- One prompt per session at a time. Track idle and busy per session. A `session/prompt` while not idle gives a client error, not a queue entry. Do not expose Router's own prompt queue.
- Register the cwd in `ProjectRegistry` at session/new. **Do not append the `SessionIndex` record here.** §9's zero-turn rule makes a persisted transcript the listability test. The prompt-turn task writes the index record at first recorded activity, with the title.
- `NewSessionResponse` carries `configOptions`. Leave an empty array and a marked TODO until the config-options task fills it.

- [ ] Absolute-cwd validation
- [ ] Per-session composition pipeline
- [ ] `profile.standard.makeSession(...)`, with the profile held strongly
- [ ] sessionId = Router ULID
- [ ] Concurrent session table with idle and busy tracking
- [ ] Registry write at new; index write deferred to first activity

## Acceptance Criteria
- [ ] `session/new` on a temp dir returns a sessionId that parses as a ULID and equals the Router session directory name on disk
- [ ] A relative `cwd` gives an error
- [ ] Two sessions at once in two temp repos read different project-layer config values, asserted through a visible behavior such as shell disabled in one
- [ ] After `session/new` alone, `projects.jsonl` holds the cwd and `sessions.jsonl` holds no record for the session
- [ ] The agent keeps the profile alive across two sequential sessions, and the second `makeSession` does not trap

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift` — on the test harness (RecordingClient and a scripted ModelLoader), with temp-dir repos
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.