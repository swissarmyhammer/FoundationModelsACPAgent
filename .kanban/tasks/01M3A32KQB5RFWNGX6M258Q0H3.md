---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mybprt3q4155hdgfqg9255
  text: |-
    Research done.

    Build environment: `Package.resolved` is not in git (`.gitignore`). The local pins were stale (Extras had no `MarketplaceSource`), and `swift package update` moved Router and Multitool past the API that main uses (`cancelCurrentTurn` is gone, `.repeatedPartRemoval` is a new event kind, `makeSessionToolsAndStaging(librarian:)` changed). Those changes belong to other cards (for example ^k0k2vn6 area: adopt the Router request/attempt/pass names). To get a baseline, I pinned each family package in the local `Package.resolved` to the last `origin/main` commit before 2026-09-23 18:30 -05:00 (the last source commit of this repository). Router is at bbad3ce, Multitool at 69b8a92, Skills at ed142ec, Extras at 0dc42cf. With these pins, `swift build --build-tests` passes and `swift test` gives 584 tests in 63 suites, all pass (1 known issue, from before).

    Names that I will use:
    - `RunTurn` -> `RunPrompt` (file `RunPrompt.swift`, with `git mv`)
    - `RunTurnResult` -> `RunPromptResult`
    - `OutOfProcessTurn` -> `OutOfProcessPrompt` (file `OutOfProcessPrompt.swift`, with `git mv`)
    - `RunTurn.turn(over:in:prompt:into:reporting:interruptedBy:)` -> `RunPrompt.send(over:in:prompt:into:reporting:interruptedBy:)`. A function with the name `prompt` and a parameter `prompt` does not read clearly, and "send" is the action.
    - `AgentExitCode(turn:)` -> `AgentExitCode(prompt:)`
    - Test support `ResumeSessionFixture.runTurn(_:)` -> `runPrompt(_:)` (the acceptance `rg` includes `Tests`).
    - User-visible help text of `run`: "Run one turn, ..." -> "Run one prompt, ...", and the argument help "The prompt of the one turn." -> "The text of the one prompt." No test reads these strings. README.md and cli-plan.md show the same line, so I change them too.
  timestamp: 2026-09-28T21:22:30.298875+00:00
- actor: claude-code
  id: 01m3myn39a5jwz0g1pae5bpdre
  text: |-
    Implementation landed. Correction to the research comment: the Router adoption card is ^tz867gz ("Adopt the Router request/attempt/pass names and the new request events"). The id "^k0k2vn6" in that comment is not a card id.

    What changed:
    - `git mv` RunTurn.swift -> RunPrompt.swift and OutOfProcessTurn.swift -> OutOfProcessPrompt.swift.
    - `RunTurn` -> `RunPrompt`, `RunTurnResult` -> `RunPromptResult`, `OutOfProcessTurn` -> `OutOfProcessPrompt`, `RunTurn.turn(over:...)` -> `RunPrompt.send(over:...)`, `AgentExitCode(turn:)` -> `AgentExitCode(prompt:)`, test support `ResumeSessionFixture.runTurn(_:)` -> `runPrompt(_:)`.
    - Doc comments in RunPrompt.swift, OutOfProcessPrompt.swift, RunCommand.swift and ExitCode.swift now say "prompt" for the agent unit. ACP words (`end_turn`, `.endTurn`, `maxTurnRequests`) did not change. The exit code table rows did not change.
    - `run` help: "Run one prompt, and print the answer. This is the default." and "The text of the one prompt. ..." README.md and cli-plan.md show the same line.
    - Other files: only symbol references (InterruptHandler.swift, CLICompositionFixture.swift, and the test call sites). The "turn" prose in the other test files stays for ^mdf7fr, and the prose in other source files stays for ^qe0awe.

    Environment note for the next agent: the local `Package.resolved` (not in git) now pins the family packages to the 2026-09-23 revisions from the research comment. `swift package update` breaks the build of main until ^tz867gz and the Multitool `makeSessionToolsAndStaging` change are adopted.
  timestamp: 2026-09-28T21:27:38.026335+00:00
- actor: claude-code
  id: 01m3myn6zdchwjjbhn3af7zzwt
  text: |-
    ### implement — changed
    - evidence: 17 files — Sources/acp-agent/RunPrompt.swift (renamed from RunTurn.swift), Sources/acp-agent/OutOfProcessPrompt.swift (renamed from OutOfProcessTurn.swift), Sources/acp-agent/RunCommand.swift, Sources/acp-agent/ExitCode.swift, Sources/acp-agent/InterruptHandler.swift, README.md, cli-plan.md, Tests/FoundationModelsACPAgentTests/{CompositionInterruptTests,EventLineWriterTests,ExitCodeTests,InterruptTests,MultiRootConfinementTests,RunCommandTests,SessionLifecycleTests,SessionResumeTests}.swift, Tests/FoundationModelsACPAgentTests/Support/{CLICompositionFixture,ResumeSessionFixture}.swift. `rg -n "RunTurn|runTurn|OutOfProcessTurn" Sources Tests` gives no result. `swift build --build-tests` passes with no warnings from the project. `swift test`: 584 tests in 63 suites pass (1 known issue from before), the same count as before the change.
    - next: /review
  timestamp: 2026-09-28T21:27:41.805153+00:00
position_column: doing
position_ordinal: '80'
title: Rename the "turn" types of the acp-agent CLI to "prompt"
---
## Why

The rule of the plan (see the library rename task): "prompt" is the agent unit, "turn" stays only for ACP protocol words. The CLI target `Sources/acp-agent` has its own "turn" names.

## What

Proposed names (the implementer can propose better names in a comment first):

| Now | New |
|---|---|
| `RunTurn` (`Sources/acp-agent/RunTurn.swift`) | `RunPrompt` (file `RunPrompt.swift`, with `git mv`) |
| `RunTurnResult` | `RunPromptResult` |
| `runTurn` | `runPrompt` |
| `OutOfProcessTurn` | `OutOfProcessPrompt` |

1. Rename in `Sources/acp-agent/RunTurn.swift`, `Sources/acp-agent/RunCommand.swift`, and each other file that `rg -n "RunTurn|runTurn|OutOfProcessTurn" Sources Tests` finds.
2. Update the tests that call them (`Tests/FoundationModelsACPAgentTests/RunCommandTests.swift` and others from the same `rg`).
3. Do not change user-visible CLI output or exit codes. If a message says "turn" for the agent unit, change the word to "prompt", and update the test that reads the message.

## Acceptance Criteria

- [x] `rg -n "RunTurn|runTurn|OutOfProcessTurn" Sources Tests` gives no result.
- [x] The exit code table and the stdout contract do not change.
- [x] `swift build` and `swift test` pass.

## Tests

- [x] No new behavior. The current `RunCommandTests` and `CLIProcessTests` are the proof.
- [x] Run `swift test`. All pass, with the same test count as before.

## Workflow
- Use `/tdd` — for a rename, the green suite before and after the change is the test. #generation-queue