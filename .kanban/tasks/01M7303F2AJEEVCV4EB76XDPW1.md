---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7306vcegtwy9fmp5788gpsa
  text: 'Decision from testudoapp-75 (2026-11-10): each agent has this style, and sub-agent runs are included. If a sub-agent run builds its instructions outside InstructionsAssembler, give it the same StyleInstructions.text first, and add a test for it. If that change is large (for example a new API in FoundationModelsAgents), stop and report it to testudoapp-75 first. testudoapp-75 will decide.'
  timestamp: 2026-11-10T15:11:15.854935+00:00
- actor: claude-code
  id: 01m73dd091twf3rvpxycq3gd55
  text: |-
    Research (item 4, sub-agent runs). Result: sub-agent runs do NOT go through InstructionsAssembler.

    - The main session: SessionSetup calls InstructionsAssembler.assemble (agent text from AgentRunner.sessionAgentInstructions / defaultAgentInstructions). The style text can go first there.
    - A sub-agent run: AgentsComposition makes AgentEnvironment.make(...) and AgentRunner(registry:environment:). The runner makes each run session in FoundationModelsAgents `AgentSessionMaker.resolveSetup(for:family:)`. Its private `instructions(parts:in:)` joins `AgentsMd.documents(from: workingDirectory)` texts, then the rendered body, then the skill bodies. A new run (`makeSession`) and a restored run (`AgentRun` restore) both use `resolveSetup`.
    - No host hook exists to put a text before the AGENTS.md texts: not in AgentEnvironment.make (pinned 8cf1d43), not in the sibling main (79f1428). A prefix on the agent body is not a fix: AGENTS.md comes before the body, so the order is wrong, and it is a build-around.

    The exact API that is necessary in FoundationModelsAgents:
    1. `AgentEnvironment.make(..., instructionsPreamble: String? = nil, ...)` (and the internal `init`), stored as `public let instructionsPreamble: String?`.
    2. `AgentSessionMaker.instructions(parts:in:)` returns `([instructionsPreamble] + documents.map(\.text) + parts)` joined with `instructionsSeparator`, with a nil or empty preamble left out. Thus new runs and restored runs (both through `resolveSetup`) start with the text.
    3. `AgentRunner.sessionAgentInstructions(for:)` and `defaultAgentInstructions()` do NOT add the preamble, because InstructionsAssembler adds the style text to the main session one time.
    4. A FoundationModelsAgents test: a run with a preamble and an AGENTS.md in its working folder gets instructions that start with the preamble, then the AGENTS.md text, then the body.

    Then in this package: AgentsComposition passes `instructionsPreamble: StyleInstructions.text`, and a test confirms that a sub-agent run starts with the style text.

    The decision of testudoapp-75 says: stop and report a new FoundationModelsAgents API first. Thus I made no code change. Items 1, 2, 3 and 5 wait for the decision, because the decision can change where StyleInstructions lives (this package or a shared package).
  timestamp: 2026-11-10T19:01:48.961787+00:00
- actor: claude-code
  id: 01m73dd30r25kz9rnzkkthqzn3
  text: |-
    ### implement — stuck
    - evidence: no files changed. Sub-agent run instructions come from FoundationModelsAgents AgentSessionMaker.resolveSetup / instructions(parts:in:) (pin 8cf1d43), not from InstructionsAssembler. The API that is necessary: AgentEnvironment.make(instructionsPreamble:), first in AgentSessionMaker.instructions(parts:in:), not in sessionAgentInstructions/defaultAgentInstructions.
    - next: testudoapp-75 decides on the FoundationModelsAgents API (a card on that board, then a pin update here). Then do items 1-5 of this card with /tdd.
  timestamp: 2026-11-10T19:01:51.768858+00:00
- actor: claude-code
  id: 01m73de6dz0y8d1xydqepwe3xx
  text: 'SCOPE CHANGE (2026-11-10, orchestrator): this task does the main session only: `StyleInstructions.text` first in `InstructionsAssembler.assemble`, for each base prompt case, and the change of `BuiltinInstructions`. The sub-agent runs move to the new follow-up task ACPA-20b, which waits for the FoundationModelsAgents `instructionsPreamble` API. Keep `StyleInstructions` public, so ACPA-20b can pass it to `AgentEnvironment.make`.'
  timestamp: 2026-11-10T19:02:28.031885+00:00
- actor: claude-code
  id: 01m73dgtg2y90dpr4zvztge6et
  text: |-
    Research (main session scope).
    - `InstructionsAssembler.assemble` makes `sections` with the base prompt first (`basePrompt`: Instructions.md, else the agent text, else BuiltinInstructions). The style text goes before it as a new first section. This covers all five base prompt cases, because SessionSetup gives each case to `assemble` as `agent:` and `workingDirectoryAgent:`.
    - Existing tests that compare the exact start of the instructions must change: InstructionsAssemblerTests (`== BuiltinInstructions.text`, `hasPrefix("DEFAULT-AGENT-TEXT")`), ComposedSessionEndpointsTests, SessionAgentTests (`hasPrefix(<agent body>)`), InstructionsEjectTests (`before == BuiltinInstructions.text`). Plan: one test helper `StyleInstructions.prefixed(_:)` in the test target, and `sectionSeparator` becomes internal so that the helper does not repeat "\n\n".
    - `acp-agent instructions eject` writes only BuiltinInstructions.text. The style text is not part of the ejected file, because the assembler puts it before every base prompt, also before an Instructions.md.
    - BuiltinInstructions "Answers": only "Give the result first, then the reason." is the same as the style text. "Report the true result" (a safety rule, a test checks it) and "Show the path of each file that you changed" stay.
    - README: add a link to StyleInstructions.swift beside the link to BuiltinInstructions.swift; DocumentationSyncTests checks both links and that the README does not repeat either text.
  timestamp: 2026-11-10T19:03:54.114009+00:00
- actor: claude-code
  id: 01m73dy6bmzy3my5ts811vrpm2
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Sources/FoundationModelsACPAgent/Instructions/StyleInstructions.swift (public enum, `static let text`), Tests/FoundationModelsACPAgentTests/StyleInstructionsPrefix.swift (test helper `StyleInstructions.prefixed(_:)`). Changed: InstructionsAssembler.swift (style text is the first section; `sectionSeparator` is internal for the helper), BuiltinInstructions.swift ("Give the result first, then the reason." removed; "Report the true result" and "Show the path of each file that you changed" stay), README.md (link to StyleInstructions.swift), InstructionsAssemblerTests.swift (parameterized tests over five base prompt cases: named agent, cwd AGENT.md, default agent, Instructions.md, builtin floor), ComposedSessionEndpointsTests.swift (composed session starts with the style text), DocumentationSyncTests.swift (link and no-repeat tests parameterized over BuiltinInstructions and StyleInstructions), SessionAgentTests.swift and InstructionsEjectTests.swift (expected starts now include the style text).
    - RED: `swift test --filter InstructionsAssemblerTests` failed on the new order tests and the builtin text test, before the assembler change.
    - GREEN: `swift test` exit 0: 1918 tests in 211 suites passed, 1 known issue (the existing `withKnownIssue` in HarnessSmokeTests), 0 compiler warnings. The one "warning:" line in the log is the SwiftPM build note "missing creator for mutated node" for the mlx-swift_Cmlx bundle; it is not from the compiler and it was there before.
    - Not changed: AgentsComposition, package pins, sibling repositories. Sub-agent runs are ACPA-20b.
    - next: /review.
  timestamp: 2026-11-10T19:11:12.244121+00:00
- actor: claude-code
  id: 01m73e26t3a50dqf5q03jx4pat
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (47fd420): 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed. 9 files reviewed. README.md had no matching validator. 12 .kanban files were excluded by .reviewignore. Scope is the main session only (see SCOPE CHANGE). Sub-agent runs are ACPA-20b.
    - next: none. The task is in done.
  timestamp: 2026-11-10T19:13:23.779790+00:00
depends_on:
- 01M7302TV19EE0H603MP21Q32S
position_column: done
position_ordinal: ffffcc80
title: 'ACPA-20: Built-in style instructions — short answers in Simplified Technical English, before AGENT.md and AGENTS.md'
---
## What
Spec: ACPA-20 (TestudoApp/features/packages/foundationmodels-acpagent.md). Decision D153.

1. New `Sources/FoundationModelsACPAgent/Instructions/StyleInstructions.swift`: a `public enum StyleInstructions` with `static let text`. The text tells the agent:
   - Write answers in ASD-STE100 Simplified Technical English: short sentences, one instruction in each sentence, the active voice, one meaning for each word.
   - Keep code, commands, file paths, identifiers and quoted text as they are.
   - Give the answer first. No preamble. Do not repeat the question. Do not give a summary that the user did not ask for. A long answer is only for a request that needs it, for example a plan or a report.
2. `Sources/FoundationModelsACPAgent/Instructions/InstructionsAssembler.swift` `assemble`: put `StyleInstructions.text` first, before the base prompt (the session agent of ACPA-1a, the default agent, an `Instructions.md`, or `BuiltinInstructions`) and before the `AGENTS.md` text. It is there for every agent, also when an `Instructions.md` replaces the base prompt.
3. Remove the "Answers" text of `BuiltinInstructions.text` that the style text now gives, so the two texts do not disagree.
4. Sub-agent runs: check if the instructions of a run (FoundationModelsAgents) also go through this assembler. If not, record that in the task comment and in the reply to `testudoapp-75`; the spec text is about the session.
5. The README links to the text, the same as for `BuiltinInstructions` (`DocumentationSyncTests`).

## Acceptance Criteria
- [ ] The instructions of each new session start with `StyleInstructions.text`.
- [ ] The style text comes before the agent text and before the `AGENTS.md` text, for a named agent, a `cwd` `AGENT.md`, the default agent, an `Instructions.md` and the builtin floor.

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/InstructionsAssemblerTests.swift`: for each of the five base prompt cases, the assembled text starts with `StyleInstructions.text`, and the `AGENT.md` and `AGENTS.md` text comes after it.
- [ ] A session test composes a session and confirms that its instructions start with the style text.
- [ ] `DocumentationSyncTests` checks the README link.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #step1