---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ht8qmap1znb2kzj5bpb7da
  text: |-
    ### The project folder can be inside the synced home
    User, 2026-10-22: "the project folder will often be in the Agents folder for the mac app so 'synched folder' and 'project folder' can be the same".

    So each file that ACPAgent (and its packages) write in `<cwd>` can be synced by iCloud:
    - `.acp-agent/transcripts/<session>/` (transcript.jsonl, index.md): OK, one writer per file.
    - `.acp-agent/config.yaml` (the session settings layer): a full-file atomic write, so the last device wins or iCloud makes a conflict copy. This is acceptable for a file that people edit; write it down.
    - `.code-context/kit.db` (SQLite with WAL): NOT safe. A live SQLite database must not sync; it can corrupt, and two devices would index it. It is also large and of no use on another device. It must move to the local home.
    - `.shell/log`: machine-local; move it to the local home (it also has the unlocked append).

    ## Rule added to this card
    Per-project state that belongs to the machine lives under the local home, keyed by the project, for example `<local>/projects/<sha256 of standardized cwd>/` with `code-context/`, `shell/` and similar. Never in `<cwd>`. iCloud Drive also skips names that end in `.nosync`, for example `.code-context.nosync`; use that only as a fallback.
    - ACPAgent gives the per-project local folder to CodeContext (index location) and to the shell capability (storeDirectory) when it makes the session tools. Check that CodeContext and Multitool take a directory. If not, the change belongs to those packages; no live session owns CodeContext.
    - The project's synced data stays in `<cwd>`: the transcripts and `.acp-agent/config.yaml`.

    ## Done when (added)
    - A test: a session whose cwd is inside the synced root writes no SQLite database, WAL or shell log in its cwd.
  timestamp: 2026-10-22T12:44:38.922832+00:00
position_column: todo
position_ordinal: '8280'
title: 'One configurable home: an AgentHome that the host gives (CLI, coding style, or the Mac app), with XDG only as the CLI default'
---
User, 2026-10-22: "we DO however need to be able to configure 'the home' - like if i'm using acp agent cli or coding style or if i am using it inside of the mac app" and "so not just XDG -- but a configurable home". Sessions stay in the project folder (user's answer: session recordings live in `<cwd>/.acp-agent/transcripts`, as today). See the memory/design rule: one file per record, iCloud-safe.

## Today: six separate places
- `rootSettingsFolder` (config.yaml, Instructions.md, skills, rules, agents) — default XDG config.
- `hooksDataDirectory` (snapshot timelines) — default XDG data.
- `skillsMarketplaceCacheDirectory` — default ~/.cache/skills.
- `modelCacheDirectory` — default the Hugging Face cache.
- `transcriptLocation` (cwd or home).
- The projects registry — ~/.config/acp-agent/projects.jsonl. It becomes a Router ProjectStore over a host folder: Router card ^16ken1m, `ProjectStore(directory:)`, one `<sha256 of path>.md` per project, and no Router default.

## Change
- One value `AgentHome`, given to `ComposedAgent.compose` and to the RoutedACPAgent initializer. It has two roots:
  - `synced` (user data that must follow the user): the settings root (config.yaml, Instructions.md, _skills, _rules, agents) and `projects/` for the ProjectStore.
  - `local` (state of this machine): `hooks/` (snapshot timelines; they point into a local git checkout, so they never sync), the model cache, and the marketplace cache.
- Presets:
  - `.xdg(name:environment:)`, the CLI default and today's behavior: synced = XDG config, local = XDG data/cache.
  - `.custom(synced:local:)`, any folders.
  - The Mac app gives `synced = <iCloud container>/Documents/Agents` and `local = Application Support/<app>`. The app chooses those; ACPAgent has no app paths.
- The current separate parameters stay as overrides inside AgentHome (or are removed in favor of it). Choose the smaller API, and write the choice on the card.
- The CLI: `acp-agent --home <dir>` sets both roots (`<dir>/synced` and `<dir>/local`, or `--home` plus `--local-home`). An env var `ACP_AGENT_HOME` does the same. With neither, XDG is used. `doctor` shows the resolved home.
- Session recordings do not move: `<cwd>/.acp-agent/transcripts/<session>/` with index.md (Router ^2cqepsd).

## Done when
- A failing test first (TDD), with these cases:
  - compose with a custom AgentHome puts settings, projects, hooks and caches under the given roots, and writes nothing under ~ or XDG.
  - The XDG default keeps today's paths.
  - `--home` and `ACP_AGENT_HOME` resolve the same way.
- The full `swift test` and the bench tests pass (the bench uses the CLI default). #home #icloud