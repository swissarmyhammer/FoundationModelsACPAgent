---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1g5arhzrj1ehj1h5t6f6naf
  text: |-
    Research done. The discoveries:

    - The read verb `tools.files.read` is internal in Multitool, but `MultiTool.Registry.tools` is a public map keyed by path (`"files.read"`), and `ToolInvoker.invoke(_:content:)` is a public door that opens the existential. `ToolCatalogTests.invokeRead` already uses this pattern and decodes the wire JSON `{correction, lines}` through `ConvertibleToGeneratedContent.generatedContent.jsonString`.
    - `SessionSurface` (ToolCatalog.swift) keeps only the mounted session tools and the pool. The plan: add the read verb tool to `SessionSurface`, taken from `built.registry.tools["files.read"]` in `sessionSurface(context:)`. A disabled files section gives `nil`, and the resolver then refuses with a reason.
    - `PromptTurn.run` computes the model prompt with `promptText(from:)` (text blocks only). The plan: a new `PromptContent` type folds text, resolved resource links, and embedded resources into the model prompt; `PromptTurn` calls it when no command override is set.
    - Wire facts: ACP `EmbeddedResourceResource` is a typealias of `JSONValue`, so the fold pattern-matches the `text`/`blob`/`uri` members. `PromptCapabilities(audio:embeddedContext:image:)` — all optional markers. MCP `Tool.Content` cases: text, image, audio, resource(Resource.Content: uri/mimeType/text?/blob?), resourceLink. ACP `Role` has `.unknown(String)`; MCP `Audience` is user/assistant only.
    - The scripted backend (`ScriptedSessionBackend`) drops the prompt it receives. The harness test needs a small additive prompt recorder in the scripted seam to assert what the backend received.
    - The initialize advertisement lives in `Initialization.swift` (`advertisedCapabilities`), which builds `PromptCapabilities()` inline today. It will reference the one `PromptContent` advertisement instead.
  timestamp: 2026-09-02T04:16:43.583523+00:00
- actor: claude-code
  id: 01m1g64wx241xtc5p5097mk30m
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsACPAgent/Agent/PromptContent.swift (new), Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift, Sources/FoundationModelsACPAgent/Agent/Initialization.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Package.swift, Tests/FoundationModelsACPAgentTests/PromptContentTests.swift (new), Tests/FoundationModelsACPAgentTests/Support/ScriptedModel.swift, Tests/FoundationModelsACPAgentTests/InitializationTests.swift
    - TDD: the 26 new tests failed first (the symbols did not exist), then the implementation made them pass.
    - The InitializationTests wire assertion changed from a bare `{}` prompt marker to `{"embeddedContext": {}}` — the card requires the honest advertisement, so the old assertion described the old behavior.
    - next: test

    ### test — green
    - evidence: swift test — 261 passed, 0 failed, 0 skipped (1 pre-existing `withKnownIssue` self-test in HarnessSmokeTests reports as passed). Zero compiler warnings from this package; the one SwiftPM notice about the prebuilt mlx-swift bundle predates this task and comes from an upstream binary artifact.
    - next: commit
  timestamp: 2026-09-02T04:31:00.002320+00:00
- actor: claude-code
  id: 01m1g6f1czz6vqc7fzz9fc1wxh
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — counts: 0 findings, 0 confirmed, 1 refuted; 8 files reviewed
    - next: done — the task moves to the terminal column

    ### finish iteration 1 — done
    - implement: changed — PromptContent.swift (new), PromptTurn.swift, Initialization.swift, ToolCatalog.swift, Package.swift, PromptContentTests.swift (new), ScriptedModel.swift, InitializationTests.swift
    - test: green — swift test, 261 passed, 0 failed, 0 skipped, zero warnings from this package
    - commit: ca2bb52
    - review: clean — 0 findings
  timestamp: 2026-09-02T04:36:32.287707+00:00
depends_on:
- 01KYSV9HGFSB9VX7Z2R0SVZ8QF
- 01KYSV76CBJV66C92Z0EM2S73K
position_column: done
position_ordinal: '9380'
title: 'Prompt content: honest capabilities and resource_link resolution'
---
## What
Plan.md §12, plus §5's prompt capabilities. Create `Sources/FoundationModelsACPAgent/Agent/PromptContent.swift`.

- Advertise the prompt capabilities honestly at `initialize`. Text is the unconditional MUST. Advertise `image`, `audio` and `embeddedContext` only when the roster can act on them. On day one that likely means text and `embeddedContext` only. Decide from what the composed session really consumes, and keep the advertisement in one place next to the consumption code.
- `resource_link` is not capability-gated and can always arrive. Resolve a `file://` URI inside the session's root set. Refuse every other scheme and every out-of-bounds path with a reason. Never fetch `http://` silently (§12).

**Resolve through the files verb, not through a guard type.** `PathGuard` is internal in Multitool and cannot be named. Call `tools.files.read` and let the capability refuse an out-of-root path. The refusal arrives in band through the output's `correction` field, because the files verbs return corrections and do not throw. Turn that correction into the reasoned refusal we send.

- `embeddedContext` resources (`TextResourceContents` and `BlobResourceContents`) fold into the turn's content. `Annotations` are safe to ignore on input.
- MCP tool-result content maps straight to `tool_call_update.content`, because ACP's ContentBlock IS MCP's (§12). This is a type-to-type map in the projection.

- [x] The capability advertisement matches real consumption
- [x] `file://` resolution through the files verb, in bounds only
- [x] Non-file schemes and out-of-bounds paths refused with a reason
- [x] The files `correction` field is turned into the refusal message
- [x] MCP content-block passthrough map

## Acceptance Criteria
- [x] A prompt with a `resource_link` to a file inside the cwd puts the file text into the turn's content, received by the scripted backend
- [x] A `resource_link` to `http://…`, or to a path outside the root set, is refused with a reasoned message, and no fetch or read happens
- [x] The initialize response's prompt capabilities match exactly the content kinds the prompt path accepts, asserted by a test that enumerates both sides

## Tests
- [x] `Tests/FoundationModelsACPAgentTests/PromptContentTests.swift` — harness, with temp files inside and outside the root set
- [x] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-01 23:31)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

Clean: zero findings.