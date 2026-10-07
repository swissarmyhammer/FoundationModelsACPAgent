---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'bench: block the upstream fix sources when web is on'
---
## Why

Found in the SWE-bench run `bench/preds.code-context.jsonl` of 2026-10-05. `bench/code-context.config.yaml:44-45` sets `web: enabled: true`. In `django__django-13447` the agent used `tools.web.fetch` to get the Django ticket ("Resolution: → fixed") and the patch of the upstream commit. Transcript: `bench/preds.code-context.transcripts/django__django-13447/01M4600RK9PGR51PV1KN58XRQY/transcript.jsonl` (21 lines name `code.djangoproject.com` or `github.com/django/django/commit|pull`). Eight other instances of the run also name these URLs. A patch copied from upstream does not measure the agent, so the score of a run with web on is not valid.

## How the code works now

- `Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift:287` (`WebToolOptions`): the `web:` section takes only `enabled` and `apiKeys`. No key blocks a host or a URL.
- Sibling repo FoundationModelsMultitool, `Sources/FoundationModelsMultitool/Capabilities/Web/WebAddressGuard.swift:47-58`: `blockedHosts` and `blockedSuffixes` (`.local`, `.localhost`, `.internal`) are static. They protect against requests to local addresses. No caller can add a host.
- `Capabilities/Web/WebConfiguration.swift:150-156` (`WebFetchPolicy`): `maxBytes`, `userAgent`, `maxRedirects`. No block list.
- `Capabilities/Web/WebFetcher.swift:263` (`checkURL(of:)`) checks each request.
- `.claude/skills/swebench/SKILL.md:64` tells the user that with web on the agent can find the upstream fix. `scan.py` reports results that look like the upstream fix.

## What to do

1. Add a bench-only block list for `web.fetch`, and filter `web.search` results with the same list. Minimum entries: `code.djangoproject.com/ticket/`, `github.com/<repo>/commit/`, `github.com/<repo>/pull/`, `github.com/<repo>/compare/`, `patch-diff.githubusercontent.com`, and the mailing list archives of the repo. Apply the list to each redirect also.
2. The list must be a config key (for example `tools.web.blockedURLPrefixes`), so a normal agent session has no list. This needs a FoundationModelsMultitool change: record it as a task on that board, and name it here.
3. Set the list in `bench/code-context.config.yaml`. Give the refusal a clear text, so the model does not try the same URL again.
4. Until the list exists, report the score of each run with web on next to a run with web off, and say so in `SKILL.md`.

## Acceptance

- A bench run of `django__django-13447` with web on gets a refusal for the ticket and the commit URLs, and `scan.py` reports zero upstream-fix results.
- A session with no list can fetch these URLs.
- Tests prove the list for fetch, for a redirect, and for search results.
- `swift build` has no warnings, and `swift test` passes.

#bench #tools #upstream