---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qm5apgh8sz7ecmaqe0vjff
  text: 'Skill text available (2026-11-18): the final text of the built-in `sessions` skill is on FoundationModelsMultitool origin/main, commit a5234d76 (main head 88ada32e), version 1.1.0. The path and API did not change: `BuiltinSkills.directory` → `sessions/SKILL.md`. The text names the address forms `@<id>`, `@<short id>`, `@<slug>`, the aliases, and the receipt words `delivered`, `queued`, `sent`, `started`, `refused`. A test in Multitool checks the skill against the tool. Compare the examples of this text with the real stack output. This task still waits for the Router D199 header and event work (^jf3j3v5).'
  timestamp: 2026-11-18T15:24:46.160294+00:00
- actor: claude-code
  id: 01m7qn7jt215p1ke21jnmn4pxt
  text: |-
    Skill text update (2026-11-18): the `sessions` skill 1.1.1 is on FoundationModelsMultitool origin/main, commit e76f7d2e (main head 288eae56). It shows the message headers as Router origin/main 709d82c5 writes them:
    - A user message with a source session: `From the user, in <title> (<folder>)`, a blank line, then the text. Unknown source: `From the user, in the session <id>`.
    - A message from a session: the Router header with the `agent name:` line and the fenced block `message from another agent`.
    - The old `[message from the user, ...]` form is gone.
    Use this version (or later) for the comparison. The Router D199 work is on main, so this task waits only for ^qa7btpc on this board.
  timestamp: 2026-11-18T15:43:28.578078+00:00
- actor: claude-code
  id: 01m7rjszdfv27a3ntccep2nbfz
  text: |-
    Research (2026-11-18):
    - The skill text is `sessions/SKILL.md` 1.4.0 at Multitool 0c22a31 (root pin). Router pin eba762f.
    - IntegrationTests/Package.resolved (gitignored, local) had old pins (Multitool 36fcd84, Router fbdb448, and 6 more). I copied the 8 root pins into it by hand. This is not `swift package update`: the revisions are the root pins.
    - The stack writers: Router `Mail.agentMessageText` writes `[message from session <id>]`, the fact lines (`AgentMessageHeader.factLines`: agent, agent name, title, folder, in reply to), the notice and the fence `message from another agent`. Router `UserMessageHeader` writes `From the user, in <title> (<folder>)` or `From the user, in the session <id>`, a blank line, the text.
    - The receipt lines of the stack are the answer of `send message` (Multitool `SessionsToolText.receipts`): `- Delivered to session <id>: ...`, `- Queued for ...`, `- Started ...`, `- Sent to ...`, `- Refused ...`. The line `Sent to claude-code-2 (v2w4abc): delivered` of the skill is the composer receipt of TestudoApp (`SessionMentions.swift`), not a line of this stack.
    - The `sessions` tool reads its caller from `ToolContext.current`, thus the test sends through a scripted model tool call in session A, not through a direct call.
    - The default agent preloads the skill with `skills: [sessions]` (skills repo `agents/default/AGENT.md` 036c882). The integration package is offline (empty marketplace list), thus the test writes a project `default` agent with that key, as `SessionsSkillPreloadTests` does.
  timestamp: 2026-11-19T00:20:20.015566+00:00
- actor: claude-code
  id: 01m7rkv9y6yn4vjg9s0cx7bhjp
  text: |-
    Implementation landed (2026-11-18). No commit.

    Files (all in IntegrationTests/, no other file changed):
    - `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SessionsSkillExamplesTests.swift`: suite `SessionsSkillExamplesTests`, 6 tests: the instructions of the default session hold the skill body; each receipt word of the skill is a `SessionSendReceipt.Outcome`; the answer of `send message` to an idle session has one receipt line with the word `delivered`; the header of a session message, of a user message from a known source and of a user message from an unknown source agree with the examples.
    - `Support/SessionsSkillExamples.swift`: reads the code blocks of the rendered skill body and fills each example with the real facts. Only the values change (ids, fact values, title, folder). The labels, the line order, the notice and the fences stay as the skill writes them. Each test reads only its own example, thus a test fails only for its own example.
    - `Support/SessionsSkillScenario.swift`: the stub agent with a scripted model, a project `default` agent with `skills: [sessions]`, two sessions in one folder. The first session sends with a real `sessions` tool call (`toolCallFromFile`), and the test reads the answer from the `tool_call_update` on the wire. A user message goes through `RoutedACPAgent.sessionDirectory.send`. The prompts of the target come from `PromptRecorder`.

    Discoveries:
    - The content text of the tool answer on the wire is a JSON string (`"- Delivered to session ..."`), thus the test decodes it.
    - Result: the shipped skill 1.4.0 (Multitool 0c22a31) agrees with the stack (Router eba762f). No Multitool card is necessary.
    - The failure path was checked: I changed the bundled copy of SKILL.md in `IntegrationTests/.build` (`agent name` to `agent title`, the notice sentence, `queued` to `waiting`, the two `From the user, in` lines). Each changed example failed its own test, and the message named the example (for example `The sessions skill example `[message from session 01JD3X9K7QZ8M2N4P6R8T0V2W4]` does not agree with the text that the stack wrote`, with the filled example and the real prompt). Then I copied the original file back.
    - `IntegrationTests/Package.resolved` (gitignored, local only) had old pins. I copied the 8 root pins into it (Multitool 0c22a31, Router eba762f, Extras bd5009e, Agents 555eaad, Skills 924ffd6, ACP 602c14c, ACPClient fed61b9, mlx-swift-lm 8e3daa7). No `swift package update`.

    ### implement — changed
    - evidence: 3 files — IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/SessionsSkillExamplesTests.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SessionsSkillExamples.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Support/SessionsSkillScenario.swift; no Multitool card (the examples agree)
    - next: /review

    ### test — green
    - evidence: `swift build --package-path IntegrationTests --build-tests` Build complete!, 0 warnings in project sources; `swift test --package-path IntegrationTests --skip-build --filter SessionsSkillExamplesTests` 6 tests in 1 suite passed; `swift build --build-tests` Build complete!, 0 warnings; `swift test --skip-build` 2379 tests in 250 suites passed (1 known issue, HarnessSmokeTests, which was there before)
    - next: /review
  timestamp: 2026-11-19T00:38:32.134965+00:00
depends_on:
- 01M7QCBBA8BX23JY4SFZX4K6R4
position_column: doing
position_ordinal: '8180'
title: 'D200: integration test that the sessions skill examples agree with the real stack output'
---
Decision D200 in `TestudoApp/features/decisions.md` (commit d1895ba). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-sessions-skill.md`, the integration test. Draft skill text: `sessions-skill-SKILL.md` in the same folder.

## Dependency

- ^zx4k6r4 (the built-in layer of the skills stack).
- The D199 Router change: the header of a user message with a source session (`router-brief-at-sessions.md`, Router task 01M7NQNGH4YGB2Y1SS0JF3J3V5 and the tasks before it). Do not start until it is available.

## Change

Add a test in `IntegrationTests` with the real in-process stack and the Router session directory:

1. Start two sessions in one folder.
2. Make sure that the instructions of the default session hold the body of the `sessions` skill.
3. Send a message from one session to the other with the `sessions` tool, and send a user message with a source session.
4. Compare the receipt lines and the message headers that the real stack writes (`[message from session <id>]` with the fact lines, and the header of a user message with a source session) with the examples in the skill text.

When they do not agree, change the skill text in FoundationModelsMultitool, not the stack. Tell the Multitool session through a message or a card on its board (`sah --cwd <repo> tool kanban task add`).

## Tests

- The test above passes with the shipped skill text.
- The test fails with a clear message that names the example that does not agree. #d200 #sessions-skill #d199