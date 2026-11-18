---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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