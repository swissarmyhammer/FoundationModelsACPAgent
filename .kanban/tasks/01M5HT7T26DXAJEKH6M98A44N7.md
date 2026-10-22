---
assignees:
- claude-code
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