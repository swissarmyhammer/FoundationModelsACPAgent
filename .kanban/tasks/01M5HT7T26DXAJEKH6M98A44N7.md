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
- actor: claude-code
  id: 01m5hxvw9fj8vrxaqp1dmnwe2a
  text: |-
    ### User, 2026-10-22: the home and the dotfolder stacks
    "yeah for cli - 'home' is XDG based so a .config/<some name> -- probably acp-agent by default or whatever you are using now. testudo passes the home based on icloud. but -- we need to make sure all the 'home' is used correctly in the dotfolder stacks"

    - CLI: the home is XDG, `~/.config/acp-agent` (the `name` used now). The local part is the XDG data/cache folders under the same name.
    - Testudo: passes its iCloud-based home.
    - REQUIRED: every DotfolderStack (FoundationModelsExtras) that ACPAgent builds or hands to a package takes its user (home) layer from AgentHome. Nothing reads `~`, `$HOME/.<name>`, `XDG_CONFIG_HOME` or the process cwd on its own. This covers:
      - config.yaml and settings (SettingsFolders);
      - Instructions.md;
      - skills, both the user layer and the marketplace cache;
      - agents (FoundationModelsAgents, AG-10);
      - rules (FoundationModelsRules);
      - hooks;
      - each other stack found by the audit.
    - First step of the work: an audit table on this card. One row per stack or folder that ACPAgent or a package it composes reads or writes, with: who builds it, its home layer today, its project layer, and the change. Grep for DotfolderStack, homeDirectoryForCurrentUser, NSHomeDirectory, XDG_, ".config", and FileManager.default.currentDirectoryPath in Sources and in .build/checkouts.
    - A test: with a custom AgentHome in a temp folder, and HOME and the XDG variables pointed at another empty temp folder, a composed session plus one prompt touch nothing under that other folder. All stacks read their user layer from the custom home.
  timestamp: 2026-10-22T13:47:32.015607+00:00
- actor: claude-code
  id: 01m5hy9j94cxgdfaaknkgd6afw
  text: |-
    ### Audit: every folder that ACPAgent or a package it composes reads or writes

    Grep of Sources/ and .build/checkouts/*/Sources for DotfolderStack, homeDirectoryForCurrentUser, NSHomeDirectory, XDG_, ".config", currentDirectoryPath (and .cache, HF_*, SKILLS_MARKETPLACE_CACHE, .code-context, .shell, cachesDirectory). FoundationModelsRules is not a dependency: no package reads a rules folder yet; ACPAgent only names it (SettingsFolders.Kind.rules). Web and MCP are inside Multitool now.

    | Folder / stack | Who builds it | Home (user) layer today | Project layer | Change | Where |
    |---|---|---|---|---|---|
    | config.yaml + Instructions.md (SettingsFolders .configuration, ConfigurationLoader, SettingsStore, InstructionsAssembler) | ACPAgent `SettingsFolders.stack(for:)` -> Extras `DotfolderStack(name:workingDirectory:environment:)` | no root: `$XDG_CONFIG_HOME/acp-agent` or `~/.config/acp-agent` (Extras reads `homeDirectoryForCurrentUser`); with `rootSettingsFolder`: `<root>/` | `<cwd>/.acp-agent/` | SettingsFolders takes `AgentHome`; user layer = home (XDG preset keeps `$XDG_CONFIG_HOME/acp-agent`; custom = `<synced>/`); always passes `userDirectory:` so Extras never reads ~ | this repo |
    | skills user layer (SkillsRegistry via ToolCatalog.makeSkillsSource) | ACPAgent SettingsFolders .skills -> Skills `SkillsRegistry(stack:)` (Skills reads no folder itself) | `$XDG_CONFIG_HOME/skills` or `<root>/_skills` | `<cwd>/.skills/` | from AgentHome (XDG keeps `$XDG_CONFIG_HOME/skills`; custom `<synced>/_skills`) | this repo |
    | skills marketplace cache (also the marketplace agents) | ACPAgent `MarketplaceStore(cacheDirectory:)` | host value, else `SKILLS_MARKETPLACE_CACHE`, else `~/.cache/skills/marketplaces` | - | from AgentHome (XDG keeps `MarketplaceStore.cacheDirectory(environment:)`; custom `<local>/skills-marketplace`) | this repo |
    | agents (FoundationModelsAgents AG-10) | ACPAgent SettingsFolders .agents -> `AgentRegistry(marketplaces:stack:)` (Agents computes no folder) | `$XDG_CONFIG_HOME/agents` or `<root>/` | `<cwd>/.agents/` | from AgentHome (XDG keeps; custom `<synced>/`) | this repo |
    | rules (FoundationModelsRules) | ACPAgent SettingsFolders .rules (names only; no reader yet) | `$XDG_CONFIG_HOME/rules` or `<root>/_rules` | `<cwd>/.rules/` | from AgentHome (XDG keeps; custom `<synced>/_rules`) | this repo (the reader, when it exists, takes the stack) |
    | hooks / snapshot timelines | ACPAgent `AgentHooks(dataDirectory:)` -> Hooks `HookDispatcher(dataDirectory:)`, `SnapshotStore(directory:)` (no package default) | host `hooksDataDirectory`, else `$XDG_DATA_HOME/acp-agent/hooks` or `~/.local/share/acp-agent/hooks` | - | `AgentHome.hooksDirectory` = `<local>/hooks` (XDG local = `$XDG_DATA_HOME/acp-agent`, so the same path) | this repo |
    | model cache | ACPAgent `LiveModelLoader(cacheDirectory:)` (bypasses HF cache defaults fully); doctor `SystemModelResolver` | host value, else HF_HUB_CACHE / HF_HOME/hub / `~/.cache/huggingface/hub` | - | `AgentHome.modelCacheDirectory` (XDG = the HF resolution of today; custom `<local>/models`) | this repo |
    | HF token lookup | swift-huggingface `HubClient(cache:)` tokenProvider `.environment` | reads HF_TOKEN..., then `~/.cache/huggingface/token`, `~/.huggingface/token` whatever the cache folder | - | needs a token-provider parameter on Router `LiveModelLoader` (and Extras `MLXModelLoader`) so a host can give it | OTHER PACKAGE (Router/Extras); not a folder ACPAgent can give today |
    | router metadata cache (`repo-metadata-*.json`) | Router `Router(cacheDir:)`; ACPAgent live path passes none | `~/Library/Caches/FoundationModelsRouter` | - | `AgentHome.routerCacheDirectory` (XDG nil = today; custom `<local>/router`) | this repo |
    | router recordings root | ACPAgent throwaway `$TMPDIR/acp-agent-recordings-<uuid>` | - | - | no change (a switch, not a destination) | - |
    | projects registry (`projects.jsonl`) | ACPAgent `ProjectRegistry(directory: userLayerRoot)` (SessionSetup, SessionList, RegisteredRecordingRoots, TranscriptStore) | the configuration user layer: `~/.config/acp-agent/projects.jsonl` or `<root>/projects.jsonl` | - | follows the configuration user layer (so AgentHome.synced); `AgentHome.projectsDirectory` = `<synced>/projects/` exposed for the Router ProjectStore; the registry code itself is ^am394r2's | this repo (expose only) |
    | transcripts | ACPAgent `TranscriptLocation.recordingRoot` | `home` location = `<config user layer>/transcripts/<slug>` | default `<cwd>/.acp-agent/transcripts` | no change (user's choice); the `home` variant follows the configuration user layer, so AgentHome | - |
    | session config layer | ACPAgent | - | `<cwd>/.acp-agent/config.yaml` | no change | - |
    | code-context index `.code-context/kit.db` (+ WAL, .gitignore) | CodeContext `Store(rootDirectory:)`, from `CodeContext(rootDirectory:embedder:autoInstall:eventSource:)` | - | `<cwd>/.code-context/kit.db` (hard-coded) | must go to `<local>/projects/<sha256>/code-context/`; CodeContext has NO index-folder parameter | OTHER PACKAGE: FoundationModelsCodeContext |
    | code-context LSP install record (`install-failures.json`) | CodeContext `LspAutoInstall(failureRecordDirectory:)` | `~/Library/Caches/FoundationModelsCodeContext` | - | `AgentHome.languageServerInstallRecordDirectory` (XDG = the default of today; custom `<local>/language-servers`) | this repo |
    | LSP server binary search | CodeContext Languages/*.swift | `~/.cargo/bin`, `~/go/bin`, `~/.local/bin` (read only, PATH-like) | - | no change (tool lookup, not agent state) | - |
    | shell store (`.shell/log`) | Multitool `withShell(storeDirectory:)`; ACPAgent passes `tools.shell.storeDirectory` (null by default) | - | with null: PROCESS cwd + `/.shell` (not the session cwd!), fallback `$TMPDIR/.shell-<uuid>`; doctor checks `<session cwd>/.shell` | default to `<local>/projects/<sha256>/shell/`; config key still wins; doctor checks the same folder | this repo |
    | Multitool ShellDotfolder userURL/projectURL | Multitool (internal, no caller) | `$XDG_CONFIG_HOME/shell` | git root/.shell | none (unused) | - |
    | Extras TemplateEngine `current` value, AgentsMd walk | Extras | reads currentDirectoryPath as a template value only; AGENTS.md walks cwd->git root | - | none | - |
    | Agents `AgentEnvironment.make(workingDirectory: = URL.currentDirectory())` | Agents | - | default argument; ACPAgent passes the session cwd | none | - |
    | CLI process cwd (`AgentComposition.processWorkingDirectory`) | acp-agent | - | default `--cwd`, and the `acp` start-up stack | none (it is the project, not the home) | - |

    ### Choice: the smaller API
    `AgentHome` replaces the separate parameters: `rootSettingsFolder`, `hooksDataDirectory`, `skillsMarketplaceCacheDirectory` and `modelCacheDirectory` are removed from `ComposedAgent.compose` and from `RoutedACPAgent.init` (no overrides kept; ARCHITECTURE.md: no backward compatibility). `home:` is required in both, so XDG is only the CLI default (`AgentComposition`).

    ### XDG preset = today's paths
    synced = `$XDG_CONFIG_HOME/acp-agent`; the per-kind user layers stay `$XDG_CONFIG_HOME/<dotfolder>` (skills, agents, rules) as today; local = `$XDG_DATA_HOME/acp-agent` (hooks unchanged). The two caches (marketplace, HF models) stay at the shared caches of today, so the CLI/bench sees no path change. New for the CLI: the shell log and (once CodeContext allows) the index leave the project folder for `$XDG_DATA_HOME/acp-agent/projects/<sha256>/`.
  timestamp: 2026-10-22T13:55:00.516630+00:00
- actor: claude-code
  id: 01m5hynj44h1q844fvjj5b4t08
  text: |-
    ### Needed from other packages (not edited here, per the rules)

    1. **FoundationModelsCodeContext — index location (BLOCKS the code-context half of "no SQLite/WAL in cwd").**
       Today `Store.init(rootDirectory:)` (Index/Store.swift) hard-codes `indexDirectory = <rootDirectory>/.code-context` and `databaseURL = …/kit.db`, and writes `.code-context/.gitignore`. The only public initializer is `CodeContext(rootDirectory:embedder:autoInstall:eventSource:)` (CodeContext.swift); the internal init and `CodeContextManager.init(embedder:autoInstall:eventSource:)` also take no index folder.
       Needed: a public parameter that separates the indexed root from the index folder, e.g. `CodeContext(rootDirectory: URL, indexDirectory: URL? = nil, embedder:autoInstall:eventSource:)` → `Store(rootDirectory:indexDirectory:)`, with `nil` keeping `<root>/.code-context`. The index folder must hold `kit.db`, its WAL/SHM, and anything else the store writes; nothing may be written under `rootDirectory` when `indexDirectory` is given. ACPAgent will then pass `AgentHome.projectStateDirectory(of: cwd)/code-context` (one line in `ToolCatalog.composeCodeContext`).
    2. **FoundationModelsRouter (LiveModelLoader) / FoundationModelsExtras (MLXModelLoader) — Hugging Face token lookup.** `HubClient(cache:)` uses `tokenProvider: .environment`, which falls back to `~/.cache/huggingface/token` and `~/.huggingface/token` whatever cache folder is given. With a custom home the agent still reads those home files. Needed: a token-provider (or token) parameter on `LiveModelLoader` / `MLXModelLoader` so a host can give its own (or none).

    Everything else in the audit table is fixed in this repo (shell store, LSP install record, router metadata cache, marketplace cache, model cache, hooks, all settings stacks).
  timestamp: 2026-10-22T14:01:33.572590+00:00
- actor: claude-code
  id: 01m5j0ccdgbktky7tba7nrks2g
  text: |-
    ### Done: one AgentHome through compose, the agent, the CLI and doctor
    - `ComposedAgent.compose(name:workingDirectory:home:...)` and `RoutedACPAgent.init(...home:...)` take a required `AgentHome`. `rootSettingsFolder`, `hooksDataDirectory`, `skillsMarketplaceCacheDirectory` and `modelCacheDirectory` are removed. The live router gets `cacheDir: home.routerCacheDirectory` and the model cache of the home. `AgentHooks` has no XDG logic left.
    - The CLI resolves its home in one function, `AgentComposition.home(environment:)`: `ACP_AGENT_HOME=<dir>` gives `<dir>/synced` and `<dir>/local`. `--home <dir>` (`HomeOptions`) sets that variable, on run, acp, doctor, config show/init/path/edit, instructions eject, and snapshots list/remove. `run --out-of-process` passes the environment to the child. With neither flag nor variable, the home is the XDG home, the same paths as before.
    - `doctor` now has a `HomeDoctor` row for the synced root and one for the local root. The profile check uses the model cache of the home. `ToolsDoctor` checks the shell store that the session uses.
    - One change to the CLI default paths: the shell store moved from `<process cwd>/.shell` to `$XDG_DATA_HOME/acp-agent/projects/<sha256>/shell`.
    - Not done, because the other package has no parameter for it: the code-context index stays in `<cwd>/.code-context`. `CodeContext(rootDirectory:...)` fixes the folder of its store.
  timestamp: 2026-10-22T14:31:29.968898+00:00
- actor: claude-code
  id: 01m5j0fed0jtcnt3jv0cdxhsx9
  text: |-
    ### implement — changed
    - evidence: 482538e feat(home): AgentHome value with XDG and custom presets; 159a87a feat(home): compose, the agent and the CLI take one AgentHome; --home, ACP_AGENT_HOME and doctor rows. Pushed to main. `swift test`: 1224 tests / 135 suites passed, 0 failed, 1 known issue. `python3 -m unittest discover -s bench`: 265 OK (1 skipped). IntegrationTests package builds.
    - done: AgentHome (synced + local; .xdg(name:environment:) and .custom(synced:local:)); ComposedAgent.compose and RoutedACPAgent.init take a required `home` (rootSettingsFolder, hooksDataDirectory, skillsMarketplaceCacheDirectory, modelCacheDirectory removed); every settings stack (config, Instructions, skills, agents, rules) takes its user layer from the home; hooks, marketplace cache, model cache, router metadata cache and LSP install record come from the home; shell store defaults to `<local>/projects/<sha256 cwd>/shell` (runtime and doctor agree); `projectsDirectory` exposed only (registry code left to ^am394r2); CLI `--home <dir>` and `ACP_AGENT_HOME` resolve through one function to `<dir>/synced` + `<dir>/local`; `doctor` shows the home (HomeDoctor rows); isolation test (custom home, HOME/XDG pointed at an empty dir, compose + one prompt writes nothing there) passes. CLI default paths unchanged except the shell store (was `<process cwd>/.shell`). Transcripts and `.acp-agent/config.yaml` stay in the project.
    - NOT done (other packages, see earlier comment): code-context index still `<cwd>/.code-context/kit.db` — FoundationModelsCodeContext needs an index-folder parameter; HF token lookup still reads ~ — Router LiveModelLoader / Extras MLXModelLoader need a token-provider parameter. So the "no SQLite/WAL in cwd" done-when holds for the shell log only.
    - next: /review
  timestamp: 2026-10-22T14:33:10.304761+00:00
- actor: claude-code
  id: 01m5j1dwqst1k5c8eef0jk8ad6
  text: |-
    ### review — findings
    - evidence: review sha 6a1f665..HEAD — 1 finding (1 confirmed, 2 refuted, 42 attempted): Sources/FoundationModelsACPAgent/Configuration/AgentHome.swift:170 swift/fluent-usage (rename static factory `xdg` to `makeXDG`; the rule applies to every static factory in the file, so `custom` too, and to the card's preset names and all call sites).
    - card items: AgentHome with synced/local roots, required `home:` on compose and RoutedACPAgent.init (separate params removed, choice written), every settings stack from the home, `--home`/`ACP_AGENT_HOME`, doctor HomeDoctor rows, tests in Tests/FoundationModelsACPAgentTests (AgentHomeTests, HomeOptionsTests, OutOfProcessHomeTests, HomeDoctorTests, SettingsFoldersTests, ...). Unmet and written on the card as blocked on other packages: code-context index still in `<cwd>/.code-context` (FoundationModelsCodeContext needs an index-folder parameter); HF token lookup still reads ~ (Router LiveModelLoader / Extras MLXModelLoader need a token-provider parameter).
    - next: fix the finding, then /review again; stays in review.
  timestamp: 2026-10-22T14:49:48.025079+00:00
- actor: claude-code
  id: 01m5j1q35mm17p7e409v11qg9k
  text: |-
    ### implement — changed
    - evidence: f065690 refactor(home): AgentHome presets in the make form, makeXDG and makeCustom. TDD: callers in Tests renamed first; `swift build --build-tests` RED with "type 'AgentHome' has no member 'makeCustom'"; after the rename, AgentHomeTests/HomeOptionsTests/HomeDoctorTests GREEN (16 tests). Full `swift test`: 1224 tests / 135 suites passed, 1 known issue (HarnessSmokeTests). `python3 -m unittest discover -s bench`: 265 OK (1 skipped). IntegrationTests package builds with tests.
    - done: finding swift/fluent-usage fixed at its cause: both static factories of AgentHome now use the make form, `xdg(name:environment:)` -> `makeXDG(name:environment:)` and `custom(synced:local:)` -> `makeCustom(synced:local:)`, with the same argument labels. No other static factory exists in AgentHome.swift (`projectKey(of:)` and `baseDirectory(...)` return a String and a URL; `SettingsLayout.xdg(configHome:)` is an enum case, not a factory). Callers updated: AgentComposition.home(environment:), the ComposedAgent doc comments (example and parameter docs), AgentHome's own doc comment, README (example and The home section), AgentHomeFixture, and 10 test files. IntegrationTests uses only AgentHomeFixture, so no change there. Finding flipped to [x]; the card's Change section names the presets `AgentHome.makeXDG(name:environment:)` and `AgentHome.makeCustom(synced:local:)`.
    - note: the earlier comments keep the old names, because they record history.
    - next: /review
  timestamp: 2026-10-22T14:54:49.524966+00:00
- actor: claude-code
  id: 01m5j1x3cbxv69vsdhn7h7pgvc
  text: |-
    ### review — clean
    - evidence: review sha f7f9932..HEAD — 0 findings (14 files attempted, 0 failed); prior swift/fluent-usage finding (AgentHome.swift, xdg → makeXDG) checked and fixed in f065690
    - next: done; the parts blocked on FoundationModelsCodeContext and on Router ^gnte6er / Extras ^d7dtghb stay recorded on the card
  timestamp: 2026-10-22T14:58:06.347584+00:00
position_column: done
position_ordinal: ffff8c80
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
- Presets (static factories, named in the `make` form):
  - `AgentHome.makeXDG(name:environment:)`, the CLI default and today's behavior: synced = XDG config, local = XDG data/cache.
  - `AgentHome.makeCustom(synced:local:)`, any folders.
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

## Review Findings (2026-10-22 09:33)

> Scope: `review sha 6a1f665..HEAD` — reviewed the diffs only — lines this change added or modified. 59 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Configuration/AgentHome.swift:170` `swift/fluent-usage` — Factory methods should begin with 'make'. This static function creates and returns an AgentHome instance, making it a factory method that should be named 'makeXDG' rather than 'xdg' for clarity and consistency with Swift API conventions. Rename the static function from 'xdg' to 'makeXDG'.
