---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qgswy2azejghp7dv8c55md
  text: 'Dependency available (2026-11-18): FoundationModelsRouter origin/main 7197aa65 (^swq7jnm, with Extras b87233e). Each new root session with no title gets `SessionName.default` from its agent name (or agent id) when the directory registers it, before the `started` event, so the event already has the name. A recorded root session with no title gets the name when the directory reads it, and the directory writes it to index.md. An empty request title counts as no title. Subagents and forks get NO default name: send the start `session_info_update` only for a session that has a name. Only a rename changes the name. This task can start.'
  timestamp: 2026-11-18T14:26:05.890837+00:00
- actor: claude-code
  id: 01m7qgxrcp3mvdfskdzyyqjppf
  text: |-
    Research (implement step):
    - The first-prompt title lives in `PromptExecution.recordTitle()`, `SessionTitleRecord`, `RoutedACPAgent.makeTitleRecord`, and the flag `titleRecorded` on `ActiveSession` and `SessionBuild`, with the parameter `titleRecorded` of `activateSession`. The field `PromptExecution.send` is used only by `recordTitle()`, so it becomes dead code. Its chain (`scheduleModelPrompt(send:)` and `CommandWork.modelPrompt(send:)`) goes too.
    - `oneLineTitle` and `promptText(from:)` have no other caller in Sources.
    - The agent has no rename code. A rename is `RouterSessionDirectory.setTitle(_:of:)`. It rewrites `index.md` and the live facts.
    - After `makeBudgetedSession` returns, `session.facts.title` holds the Router default name of a new root session.
    - The resume sync (`sessionInfoSyncUpdate(recordedTitle:)`) prefers the title in the retained history over the recorded title. Thus the start update must NOT go into the retained history: if it did, a resume after a rename would send the old default name. The start update goes through the connection after the `session/new` response, like the MCP server status report.
    - Nested sessions do not go through `createSession`, so they send no start update.
  timestamp: 2026-11-18T14:28:12.310954+00:00
- actor: claude-code
  id: 01m7qhfxqke3vzd16fmp87pej9
  text: |-
    Implementation landed (not committed).
    - Removed: `SessionTitleRecord`, `PromptExecution.recordTitle()`, `PromptExecution.send`, `PromptExecution.titleRecord`, `oneLineTitle`, `promptText(from:)`, `RoutedACPAgent.makeTitleRecord`, `titleRecorded` on `ActiveSession` and `SessionBuild`, the `titleRecorded` parameter of `activateSession`, the `send` parameter of `scheduleModelPrompt`, and `send` on `CommandWork.modelPrompt`.
    - Added: `RoutedACPAgent.announceName(of:sessionId:)` in SessionSetup.swift. `createSession` calls it. It posts one `session_info_update` with `session.facts.title` after the `session/new` response, and only when the name is not empty. It does not go into the retained history: the resume sync then reads the recorded title, so a rename shows on resume.
    - Load and resume are unchanged (`syncCurrentState`).
    - Tests (PromptExecutionTests): `aNewSessionSendsItsDefaultNameBeforeTheFirstPrompt`, `theFirstPromptKeepsTheDefaultName`, `theFirstPromptSendsNoSessionInfoUpdate`, `aRenameChangesTheNameAndThePromptKeepsIt`, `aResumeAfterARenameSendsTheNewName`. All 5 failed before the change and pass after it. The old `theFirstPromptWritesTheTitleRecordWithAOneLineTitle` is removed.
    - Updated tests for the new behavior: `promptUpdates(in:)` now also drops `session_info_update`. The order lists in PromptExecutionTests, PromptFollowUpTests and CancellationTests no longer hold `.sessionInfoUpdate`. SessionSetupTests, SessionFolderTests and TranscriptStoreTests now expect the Router default names (`session`, `session-2`). In ResumeSyncTests, `aResumeOfASessionWithNoInfoSendsNoSessionInfoUpdate` became `aResumeOfASessionWithNoInfoSendsItsRecordedName`. The TranscriptStoreTests change follows the Router read-time default name, not code in this repo.
  timestamp: 2026-11-18T14:38:07.603601+00:00
- actor: claude-code
  id: 01m7qhg0t25mm0mrvfx6w9ekq5
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsACPAgent/Agent/{PromptExecution,SessionSetup,SessionBuild,SessionResume}.swift, Sources/FoundationModelsACPAgent/Commands/CommandDispatch.swift, Sources/FoundationModelsACPAgent/RoutedACPAgent.swift, Tests/FoundationModelsACPAgentTestSupport/AssertionHelpers.swift, Tests/FoundationModelsACPAgentTests/{PromptExecution,PromptFollowUp,Cancellation,ResumeSync,SessionFolder,SessionSetup,TranscriptStore}Tests.swift, Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift
    - next: review

    ### test — green
    - evidence: `swift build --build-tests` printed "Build complete!" with 0 compiler warnings; `swift test --skip-build` ran 2294 tests in 243 suites, all passed, 1 known issue that was there before this change, exit 0
    - next: review
  timestamp: 2026-11-18T14:38:10.754067+00:00
- actor: claude-code
  id: 01m7qhnxjbn9apa38w1975zgya
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD; 0 findings, 0 confirmed, 1 refuted, 21 attempted, 0 failed; 15 files reviewed; 2 files in .kanban/ not reviewed (ignore rule).
    - next: none. The task is in done.
  timestamp: 2026-11-18T14:41:24.043060+00:00
- actor: claude-code
  id: 01m7qhp5ymt139vhtnpeaq92qc
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 15 files
    - test: green — swift test --skip-build, 2294 tests in 243 suites passed; 0 compiler warnings
    - commit: 6079dd8
    - review: clean — 0 findings
  timestamp: 2026-11-18T14:41:32.628982+00:00
position_column: done
position_ordinal: ffffff8180
title: 'D199: keep the default session name; stop the title from the first prompt'
---
Decision D199 (b) in `TestudoApp/features/decisions.md` (commit 740cd1a). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/at-sessions/acpa-brief-at-sessions.md`, item 5. Plan and order: `impact-at-sessions.md` in the same folder.

## Dependency

FoundationModelsRouter, `router-brief-at-sessions.md` item 4: the Router gives each new session a default name from its agent (`claude-code`, `claude-code-2`). Do not start until the Router change is available.

## Current behavior

- `makeTitleRecord(for:entry:blocks:)` (`Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift:1125-1145`) sets the title from the first line of the first prompt, through `SessionTitleRecord` (`:91-106`), and sends a `session_info_update` (`:295-310`).

## Change

1. Remove the title from the first prompt: `makeTitleRecord`, `SessionTitleRecord`, `titleRecorded`, and the code that writes the title and sends its `session_info_update`. Remove `PromptExecution.oneLineTitle` if nothing else uses it.
2. When a session starts (`session/new`, and a new child session), read the default name that the Router gave the session and send one `session_info_update` with it, so the client shows the name at once.
3. Only a rename changes the name. Load and resume keep the current `session_info_update` (`SessionResume.swift:636-685`).

## Tests

- A new session sends a `session_info_update` with its default name before the first prompt.
- The first prompt does not change the name, and sends no `session_info_update` with a title from the prompt.
- A rename still changes the name.
- Update or remove the current tests of the first-prompt title. #d199 #at-sessions