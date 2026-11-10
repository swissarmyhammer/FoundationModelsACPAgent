---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m73detf7pd3axzc720yxm4m7
  text: 'foundationmodelsagents-d7 accepted the API as Agents task ^mpqd9de (step1), after ^1yb868r. `AgentEnvironment.make(..., instructionsPreamble: String? = nil, ...)`, stored as `public let instructionsPreamble: String?`. A run joins [preamble] + AGENTS.md documents + body + skill bodies with `instructionsSeparator`. A nil or whitespace-only preamble is left out. New runs and restored runs both get it. `sessionAgentInstructions(for:)` and `defaultAgentInstructions()` do not add it. Wait for the commit, then bump only the Agents pin.'
  timestamp: 2026-11-10T19:02:48.551129+00:00
- actor: claude-code
  id: 01m73hmage7kd2qysqhzh2gg16
  text: |-
    Agents ^mpqd9de is pushed (FoundationModelsAgents main, head 609c812; feature 3a2bfca, test fix bc848c5; swift test 939 passed; review clean). This card is no longer blocked.
    API: `AgentEnvironment.make(..., instructionsPreamble: String? = nil, sandboxProbe: SandboxProbe = .live)`. `sandboxProbe` stays the last parameter. It is stored as `public let instructionsPreamble: String?`. Each run, new and restored, joins: preamble, AGENTS.md text, body, skill bodies. A nil or whitespace-only preamble adds nothing. `sessionAgentInstructions(for:)` and `defaultAgentInstructions()` do not add it.
    Note: the probe card (AgentsComposition passes `sandboxProbe:`) and the restore card (Agents e181a24) also change the Agents pin and `AgentsComposition.make`. Do the three cards one after the other in the main tree, with one pin move to 609c812 or later.
  timestamp: 2026-11-10T20:15:43.118786+00:00
- actor: claude-code
  id: 01m73k08f2e6a5wk8v3ftsj6ah
  text: |-
    Research (implement step):
    - Pins: `swift package update FoundationModelsAgents` moved only the Agents pin, 8d0acd4 to 609c812, in the root and in IntegrationTests. No other package moved. Package.resolved is in .gitignore, thus git shows no diff for the pins.
    - `AgentRunHost.linking(_:)` copies the environment with `withRecordingRoot`, `withSessionEnding` and `withClaimCompletion`. These keep `instructionsPreamble`, because each makes a copy of the struct.
    - A test cannot read the instructions of a run through a public Agents API (`AgentRun.heldSession` is internal). The ACP agent table holds the session of each child (`ActiveSession.session`), and its transcript starts with the `.instructions` entry. The test reads that entry.
    - For a restored run, the Router replaces the leading `.instructions` entry of the transcript only when the supplied instructions differ from the recorded ones (`applyInstructionsOverride`). The restored-run test thus changes the AGENTS.md text between the record and the resume. Then the transcript shows the instructions that the restore made.
    - Main session: `SessionAgentComposition.renderedInstructions` uses `runner.sessionAgentInstructions(for:)`, which does not add the preamble. `InstructionsAssembler` adds the style text one time.
  timestamp: 2026-11-10T20:39:42.818789+00:00
- actor: claude-code
  id: 01m73kea9yvk8vg29a8245a55e
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift (`instructionsPreamble: StyleInstructions.text`, doc comment), Sources/FoundationModelsACPAgent/Instructions/StyleInstructions.swift (doc comment), README.md (instructions section), Tests/FoundationModelsACPAgentTests/SubagentInstructionsTests.swift (new: a new run and a restored run start with the style text, then the AGENTS.md text, then the body), Tests/FoundationModelsACPAgentTests/SessionAgentTests.swift (new: the main session has the style text one time), Tests/FoundationModelsACPAgentTests/Support/LeadingInstructions.swift (new shared `Transcript.leadingInstructionsText`), Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift (uses the shared reader in place of its private copy).
    - pins: FoundationModelsAgents 8d0acd4 -> 609c812 in the root and in IntegrationTests. No other package moved. Package.resolved is git-ignored.
    - TDD: both run tests failed without the change (the instructions started with the AGENTS.md text, with no style text) and pass with it. The main-session test is a confirmation and passed at its first run: `sessionAgentInstructions(for:)` adds no preamble.
    - The restored-run test changes AGENTS.md between the record and the resume. The Router replaces the leading instructions only when they differ from the record, so the transcript shows the instructions that the restore made.
    - `swift build --build-tests`: complete, no compiler warnings. `swift test`: 1951 tests in 213 suites passed, 0 failures (1 known issue is the existing `withKnownIssue` self-test in HarnessSmokeTests). `swift build --build-tests --package-path IntegrationTests`: complete. Both builds print the SwiftPM build-system note "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. That note is not a compiler warning and does not come from the source of this change.
    - next: /review
  timestamp: 2026-11-10T20:47:23.454714+00:00
- actor: claude-code
  id: 01m73kjm5kgp2eg81v0bh089tv
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (8d7c456): 1 finding (1 confirmed, 1 refuted) — Tests/FoundationModelsACPAgentTests/SubagentInstructionsTests.swift:68 reuse/reuse
    - next: implement the finding (use one shared AGENTS.md write helper), then review again.
  timestamp: 2026-11-10T20:49:44.627346+00:00
- actor: claude-code
  id: 01m73kswjwbvkmsghr0cpx57m2
  text: |-
    Finding work (implement step):
    - The fixture helper `write(_:to:under:)` is a member of the private fixture of InstructionsAssemblerTests, and `AgentInstructionsFileTests.write(_:to:in:)` is private. The new test file cannot call them. Thus a new shared helper is in the support target.
    - New: `Tests/FoundationModelsACPAgentTestSupport/AgentsFileFixture.swift`, `AgentsFileFixture.write(_:in:)`. It has the shape of `ConfigFileFixture.write(_:in:)`: it makes the folder, then writes `InstructionsAssembler.agentsFileName` atomically.
    - SubagentInstructionsTests: `writeAgentsMd(_:in:)` is removed. The two tests call `AgentsFileFixture.write`.
    - The helper also replaces four inline AGENTS.md writes, each with the same bytes and no change in behavior: SessionResumeTests (diverge test), BuiltinCommandsTests (fixture), TelemetryContentSafetyTests (`makeWorkingDirectory`), AgentInstructionsFileTests (precedence test). In AgentInstructionsFileTests the private `agentsFileName` constant had no more callers, thus it is removed. Its private `write(_:to:in:)` stays, because it also writes AGENT.md.
    - Not changed: the InstructionsAssemblerTests fixture helper. It is a general writer (skills, user and project layers, nested paths) with many callers. A change there is a refactor of an older file with risk.
  timestamp: 2026-11-10T20:53:42.620757+00:00
- actor: claude-code
  id: 01m73kt08n3x3bnhcrbtaysxxs
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsACPAgentTestSupport/AgentsFileFixture.swift (new), Tests/FoundationModelsACPAgentTests/SubagentInstructionsTests.swift, Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift, Tests/FoundationModelsACPAgentTests/BuiltinCommandsTests.swift, Tests/FoundationModelsACPAgentTests/TelemetryContentSafetyTests.swift, Tests/FoundationModelsACPAgentTests/Integration/AgentInstructionsFileTests.swift. Finding SubagentInstructionsTests.swift:68 reuse/reuse is `- [x]`. No pin change. `swift build --build-tests`: complete, 0 compiler warnings. `swift test`: 1951 tests in 213 suites passed, 0 failures (1 known issue is the existing `withKnownIssue` self-test). `swift build --build-tests --package-path IntegrationTests`: complete. The only build note is the SwiftPM "missing creator for mutated node" note for mlx-swift_Cmlx.bundle, which is not a compiler warning.
    - next: /review
  timestamp: 2026-11-10T20:53:46.389148+00:00
depends_on:
- 01M7303F2AJEEVCV4EB76XDPW1
position_column: doing
position_ordinal: '80'
title: 'ACPA-20b: Sub-agent runs start with the style text (AgentEnvironment instructionsPreamble)'
---
## What
Split from ^76xdpw1 (ACPA-20, D153) on 2026-11-10. testudoapp-75 decided that each agent, also each sub-agent run, gets the style text. A run makes its instructions in FoundationModelsAgents (`AgentSessionMaker.instructions(parts:in:)`), not in `InstructionsAssembler`.

External dependency: FoundationModelsAgents `AgentEnvironment.make(..., instructionsPreamble: String?)` (requested from foundationmodelsagents-d7 on 2026-11-10). Do not start until it is pushed.

1. Update only the FoundationModelsAgents pin.
2. `Sources/FoundationModelsACPAgent/Tools/AgentsComposition.swift` (~94): pass `instructionsPreamble: StyleInstructions.text` to `AgentEnvironment.make`.
3. Confirm that the main session does not get the text two times (`sessionAgentInstructions(for:)` does not add the preamble).

## Acceptance Criteria
- [ ] The instructions of a sub-agent run start with `StyleInstructions.text`, then the `AGENTS.md` text, then the agent body.
- [ ] A restored run starts with the same text.
- [ ] The main session has the style text one time.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/`: start a run through the `agents` tool with a working folder that has an `AGENTS.md`, and confirm the order of its instructions. Do the same for a restored run.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1

## Review Findings (2026-11-10 14:47)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Tests/FoundationModelsACPAgentTests/SubagentInstructionsTests.swift:68` `reuse/reuse` — `writeAgentsMd(_:in:)` re-implements the write of an `AGENTS.md` file that the test suite already does in other places. The fixture helper `write(_:to:under:)` and the `AgentInstructionsFileTests.write(_:to:in:)` helper do the same job. Use the existing write helper for `AGENTS.md`, or move the helper into `Tests/FoundationModelsACPAgentTestSupport` so that all AGENTS.md writes use one function. Do not add a fourth copy.
