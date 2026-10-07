---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b8wxswn0x36ks1q9eqst4r
  text: |-
    ### upstream task
    - Multitool: ^8rf1he5 (01M4B8WEPNFCNH4QFPH8RF1HE5) "files: host-given exclude patterns for the search verbs". Not implemented; waits for the Multitool user.
    - Decision sent: the host patterns stay on when a call sets respectGitIgnore: false, because the model must not be able to turn off the host rule. A test checks it.
    - This task starts when ^8rf1he5 is pushed.
  timestamp: 2026-10-07T13:29:57.820027+00:00
- actor: claude-code
  id: 01m4bm1e2vmzfxcqeze1nk8kqj
  text: |-
    ### upstream ready
    - Multitool main 3c9856ce includes ^8rf1he5: `FilesCapability.init(..., excludePatterns:)` and `withFiles(..., excludePatterns:)`. This task can start after the pin update to 3c9856ce.
  timestamp: 2026-10-07T16:44:39.899683+00:00
position_column: todo
position_ordinal: '8380'
title: 'files.grep finds the agent''s own transcripts under .acp-agent/: configure exclude patterns for the file tools'
---
## Decision (user, 2026-10-07)

The files tools get a list of exclude patterns in gitignore syntax, as an option that the host gives. Multitool must NOT hard-code any agent directory. This agent configures the patterns, and its default excludes `.acp-agent/`. plan.md §4.3 does not change: transcripts are still committed, and no `.gitignore` goes into `.acp-agent/`.

The Multitool part is a task on the Multitool board (id to be recorded here when it arrives): the files capability takes the exclude patterns, and the search verbs (`files.grep`, `files.glob`, and any other verb that walks a tree) skip a path that matches, the same as a path that `.gitignore` ignores. A read or a write of an explicit path is not changed.

## Why

Found in the SWE-bench runs. `files.grep` in the agent workspace matches the agent's own transcripts (`.acp-agent/transcripts/<session>/transcript.jsonl`). The model then reads its own earlier output as a search result. Examples: run bench/preds.code-context-1006.jsonl, django__django-13447 seq 230; run bench/preds.code-context.jsonl, two results in django__django-14411. `scan.py` counts these self-matches.

## What to do (this repo, after the Multitool task is pushed)

1. Add the config key `tools.files.exclude`: a list of gitignore patterns. The default holds `.<dotfolder name>/` (`.acp-agent/` for the CLI, from `AgentComposition.dotfolderName`, `Sources/acp-agent/AgentComposition.swift:30`). A user list replaces the default; a user can add the default back.
2. Give the list to the Multitool files capability where it is composed.
3. `config show` prints the key with its default, and the `config init` template has it.
4. Update the Multitool pin.

## Where the code is

- The transcript root: `Sources/FoundationModelsACPAgent/Transcripts/TranscriptLocation.swift:42-58` (`project` gives `<cwd>/.<name>/transcripts/`).
- `files.grep` uses the git-aware `FileWalker` (FoundationModelsMultitool `Capabilities/Files/Grep.swift:211`, `GrepEngine.swift:110`).
- The tool-section codec: `Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift`.

## Acceptance

- [ ] With the default config, `files.grep` and `files.glob` in a workspace that holds a recorded session give no line and no path from `.acp-agent/`.
- [ ] With `tools.files.exclude: []`, the old behavior returns.
- [ ] `config show` shows `tools.files.exclude` and its default.
- [ ] A bench run gives zero "files.grep results with .acp-agent/transcripts lines" in `scan.py`.
- [ ] `swift build` has no warnings, and `swift test` passes.

## Tests

- [ ] A test of the codec: absent key gives the default; an empty list gives no exclude; a user list replaces the default.
- [ ] A test that composes the files tools with the default and runs `files.grep` over a tree with `.acp-agent/transcripts/x.jsonl` that matches: the file is not in the result.
#tools #bench #upstream