---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1fsxdvxnpbaanjr4y7d2fb9
  text: |-
    Research findings before implementation:

    - Verified in ../FoundationModelsRouter: `RoutedLLM.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)` is public with defaults. `Router` has only `id`, `init`, `resolve`. The card is correct.
    - The session directory on disk: `recordingDirectory(forSessionId:recordingRoot:)` gives `<recordingRoot>/<ulid>/`. The `session.json` sidecar is written at `makeSession` time only when the router records durably (`recordingsDir` not nil). Tests must construct the stub router with a recordings directory. I will extend `makeStubRouter`/`makeStubAgent` pass-through parameters.
    - One discovery: Router gives no public read of the resolved context tokens (`SlotResolution.contextTokens` is `package`, `RoutedModel.resolution` is `package`). `TokenBudget` requires `limit`. Thus this task passes `budget: nil` with a marked TODO. The compaction config fractions connect when Router shows the resolved context. The card does not name a budget source and has no budget acceptance test.
    - `AbsolutePath` already refuses a relative path at wire decode (`RequestError.invalidParams`, -32602). The agent adds its own check in `SessionSetup` with the same error code, and a raw NDJSON wire test shows the refusal end to end.
    - The user layer root comes from `ConfigurationLoader.stack.layers` (`source == .user` always exists). `ProjectRegistry` and `TranscriptLocation.home` use it. Agent `init` gains `userDirectory:`/`environment:` test seams, in the pattern `ConfigurationLoader` documents.
    - Visible config-difference behavior for the two-repo test: `tools: skills: false` in one repo removes the `skills` tool from the composed `SessionSurface.tools` roster (pattern from ToolCatalogTests).
  timestamp: 2026-09-02T00:57:12.317945+00:00
- actor: claude-code
  id: 01m1ftat9fr57bz2bbqdehvsnt
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Agent/SessionSetup.swift (new), Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift (new), Tests/FoundationModelsACPAgentTests/StubProfileFixtures.swift. TDD: the new suite failed first for the missing API, then all 158 tests pass.
    - next: run the test step, then commit and review.

    Details:
    - `newSession` composes per cwd: ConfigurationLoader → InstructionsAssembler (with the skills registry) → ToolCatalog.sessionSurface (MCPComposition runs inside it) → `profile.standard.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:)`. Grammar and agentSpawn stay nil.
    - The sessionId is `session.id.description`; the table `sessions: [SessionId: ActiveSession]` lives on the agent actor and carries config, instructions, confinement, transcript directory, surface, and idle/busy availability.
    - ProjectRegistry records the cwd; no SessionIndex write.
    - `budget: nil` with a marked TODO — Router shows no public resolved context; follow-up task ^f40jzjy created.
    - Agent init gains `userDirectory:`/`environment:` test seams; `makeStubAgent` gains `recordingsDirectory:`/`userDirectory:` pass-through with an empty environment.
  timestamp: 2026-09-02T01:04:31.023823+00:00
- actor: claude-code
  id: 01m1ftc8qdv3354sfxz0pr4e2p
  text: |-
    ### test — green
    - evidence: `swift test` — 158 tests in 18 suites passed, 0 failed, 0 skipped; `swift build --build-tests` shows zero compiler warnings. The one "known issue" is HarnessSmokeTests' deliberate negative check of `expectOrderedSubsequence`, which runs and can fail — not a skip.
    - next: commit, then review.
  timestamp: 2026-09-02T01:05:18.573426+00:00
- actor: claude-code
  id: 01m1ftcq4fhs73xs1p08whx3mk
  text: |-
    ### commit — changed
    - evidence: 531d369 feat(agent): compose session/new into a root Router session with the actor-held table (8 files, +593/-29, kanban state included)
    - next: review 531d369 (HEAD~1..HEAD).
  timestamp: 2026-09-02T01:05:33.327045+00:00
- actor: claude-code
  id: 01m1fth30kjq4x65bsmqm752yy
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` on 531d369 — 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed; the 4 `.kanban/` files were excluded by .reviewignore. No prior findings sections existed.
    - next: task moved to done.
  timestamp: 2026-09-02T01:07:56.563693+00:00
- actor: claude-code
  id: 01m1fthbq83z8hqqctp67pmv5v
  text: |-
    ### finish iteration 1 — done
    - implement: changed (SessionSetup.swift + RoutedACPAgent.swift + SessionSetupTests.swift + StubProfileFixtures.swift; TDD red first)
    - test: green (swift test — 158 passed, 0 failed, 0 skipped, 0 warnings)
    - commit: 531d369
    - review: clean (0 findings on HEAD~1..HEAD) → task moved to done
  timestamp: 2026-09-02T01:08:05.480577+00:00
depends_on:
- 01KYSV5GF5FKH2S0ZSRQD8DA4Z
- 01KYSV6BNDNMQ9T6RKFQ3P1ZD2
- 01KYSV6QHJ631K7T7FRF4B8338
- 01KYSV76CBJV66C92Z0EM2S73K
- 01KYSV83KNKXPSMJMQX5TFSPGC
- 01KYSVR3HG5TB7G8DA7NZ60Y96
- 01KYSV93N6D4RWYQ7XMCHQ21GW
position_column: done
position_ordinal: 8c80
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

- [x] Absolute-cwd validation
- [x] Per-session composition pipeline
- [x] `profile.standard.makeSession(...)`, with the profile held strongly
- [x] sessionId = Router ULID
- [x] Concurrent session table with idle and busy tracking
- [x] Registry write at new; index write deferred to first activity

## Acceptance Criteria
- [x] `session/new` on a temp dir returns a sessionId that parses as a ULID and equals the Router session directory name on disk
- [x] A relative `cwd` gives an error
- [x] Two sessions at once in two temp repos read different project-layer config values, asserted through a visible behavior such as shell disabled in one
- [x] After `session/new` alone, `projects.jsonl` holds the cwd and `sessions.jsonl` holds no record for the session
- [x] The agent keeps the profile alive across two sequential sessions, and the second `makeSession` does not trap

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/SessionSetupTests.swift` — on the test harness (RecordingClient and a scripted ModelLoader), with temp-dir repos
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Notes from implementation
- The budget: Router shows no public read of the resolved context tokens, so `session/new` passes `budget: nil` with a marked TODO. Follow-up task: ^f40jzjy.
- The config-difference behavior in the two-repo test uses `tools: skills: false` (the skills tool leaves the composed roster), the same kind of visible behavior as a disabled shell.