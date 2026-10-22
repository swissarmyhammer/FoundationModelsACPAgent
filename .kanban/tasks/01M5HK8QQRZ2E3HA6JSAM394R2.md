---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ht7z0r4nr7cbcbwb0x45ef
  text: |-
    ### Router plan (Router main 1c57421d; nothing built yet)
    - Router cards:
      - ^2cqepsd: index.md replaces session.json, facts.json and sessions.jsonl, and sessions are listed by folder.
      - ^s9dftdp: only transcript.jsonl goes onto JSONLFile. SessionIndex and the ed7b7c27 writer are deleted.
      - ^16ken1m: ProjectStore replaces ProjectRegistry.
      - Both ^2cqepsd and ^16ken1m wait on the Extras FrontmatterDocument save card 01M5HS4GB26B9S1XGRGV6WCCQT.
    - API:
      - `directory.setTitle(_:for:)`, which ACPAgent calls with the first-prompt title.
      - `RouterSessionDirectory.setAdditionalDirectories(to:for:)`.
      - `RouterSessionDirectory.recordedSessions(in: recordingRoot) -> [SessionRecord]`, with sessionId, cwd, title, updatedAt, additionalDirectories, the fork parent and baseline, the facts, and firstActivityAt.
      - Delete = remove the session folder.
    - Zero-prompt rule: Router sets `firstActivityAt` at the first submission. session/list keeps the records where `firstActivityAt != nil`. ACPAgent calls nothing for this, only setTitle.
    - `ProjectStore(directory:)`: the host gives the folder; one `<sha256 hex of standardized path>.md` per project; no Router default. The folder comes from the new AgentHome card (synced root, `projects/`).
    - User answer: session recordings stay in the project folder (`<cwd>/.acp-agent/transcripts`).
  timestamp: 2026-10-22T12:44:13.720771+00:00
- actor: claude-code
  id: 01m5jj3jg2t7cbzm8pbfk5vn08
  text: |-
    ### finish — skipped (blocked upstream), 2026-10-22
    - Router ^2cqepsd (index.md, recordedSessions) is in review, and ^16ken1m (ProjectStore) is in todo; neither is on Router main. So the API this card needs does not exist yet.
    - Router main already deleted SessionIndex and sessions.jsonl (70a5d3b9). This repo still uses Router's SessionIndex, so DO NOT run a full `swift package update` before this card is done. Update only the packages that a card needs.
    - Also moved here from ^mbs9b3m: "TranscriptStore reads index.md" (in place of session.json).
  timestamp: 2026-10-22T19:41:15.650207+00:00
position_column: todo
position_ordinal: '80'
title: 'ROUTER-3: no sessions.jsonl and no projects.jsonl — list sessions from the folder and index.md, and keep projects in a host-given folder with one file per project'
---
User decision of 2026-10-22, in the user's words: "projects.json location needs to be configurable so that TestudoApp can have that in the icloud app folder. and its gonna need to NOT be a JSONL, but instead a folder with a file per project to avoid merge errors. i also think that sessions.jsonl needs to be eliminated, we should be able to directory list sessions and use the being created by router index.md" and "a big user of this will be testudo which will have a mac app style icloud folder that will sync files".

## The rule
iCloud syncs files between devices, and a lock does not work across devices. So no file of the session records or the project records is written by two sessions or two devices. One file per record:
- one folder per session, with its own index.md;
- one file per project.

## Waits on Router
The Router session owns ProjectRegistry, SessionIndex and index.md (its card ^2cqepsd; ^s9dftdp must change). Asked on 2026-10-22:
- index.md frontmatter holds sessionId, cwd, title, updatedAt, additionalDirectories and the fork data.
- An API that ACPAgent calls to set the title (at the first prompt) and additionalDirectories.
- The rule for a session with no prompt.
- ProjectRegistry over a folder that the host gives, with one file per project.

## Change in ACPAgent, when Router has it
- session/list, session/resume, session/delete and the snapshots inventory (`acp-agent snapshots list/remove`, RegisteredRecordingRoots, SnapshotInventory) read the folder and index.md, not sessions.jsonl.
- Remove the ACPAgent sessions.jsonl writer: PromptExecution.makeFirstActivity and the FirstActivity write (PromptExecution.swift:1040-1053, :278-289), the resume append (SessionResume.swift:472-480), and the delete rewrite (SessionLifecycle.swift:339-351). Give Router the title and additionalDirectories instead.
- `ComposedAgent.compose` and the RoutedACPAgent initializer take the projects folder from the host (for example `projectsDirectory: URL?`) and pass it to Router. The CLI default stays under XDG (~/.config/acp-agent/projects/). TestudoApp gives a folder in its iCloud app folder.
- `recordSessionStart` (SessionSetup.swift:703-706) writes only the file of its own project.

## Done when
- A failing test first (TDD), with these cases:
  - Two sessions in one folder give two session folders, each with an index.md that holds its title and additionalDirectories. session/list shows both, and no sessions.jsonl exists.
  - Two projects give two files in the projects folder that the host gives.
  - A delete removes only the folder of its own session.
- The full `swift test` and the bench tests pass. The bench harness reads no sessions.jsonl; check bench/*.py. #router-3 #blocked-upstream #icloud