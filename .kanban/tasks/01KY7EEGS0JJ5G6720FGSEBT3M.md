---
comments:
- actor: claude-code
  id: 01kyfygnsjwzdb26mhwwqbhyn6
  text: |-
    Upstream ask filed on the **FoundationModelsShelltool** board 2026-07-26 (cross-repo, so not expressible as `depends_on`):

    - `f1hcn7g` — **ShellPolicy: an `ask` outcome plus persisted always-decisions.** `check(command:)` / `check(environment:)` / `check(workingDirectory:)` all return `String?` — a rejection reason or nil. There is no third outcome, so `session/request_permission` has nowhere to hook, and `allow_always` / `reject_always` have nowhere to persist. This plan's §9.1 assigns that persistence to the stacked `ShellPolicy`, which first requires the policy to have the concept.

    Two design calls were pushed upstream rather than decided here, because they are security-relevant and belong with the code: what an "always" decision is keyed on (a raw command string is too narrow to be useful and unsafe if wildcarded carelessly), and the persistence scope (recommendation recorded: project + user layers, session-scoped as the non-persistent default).

    Also filed there: `q819s54` / `416c6yq` (raw bytes + chunk stream) — those block the terminal follow-up `4c3hb7j`, not this task, but `416c6yq` also enables incremental `tool_call_content_chunk` for ordinary shell tool calls, which is in *this* task's scope.

    **FoundationModelsFileTool** needs nothing blocking. Filed there: `d7jwam5` (structured change set + git patch for ACP diff content — mostly a projection over already-public `EditOutcome` / `PatchResult` / `PatchParser.Hunk`) and `939nnzx` (multi-root `PathGuard`, deferred — only needed if the decision to ship single-root and not advertise `additionalDirectories` reverses). Noted there that `GrepMatch`'s 1-based `line` is load-bearing for ACP `locations` and must not be changed inadvertently.
  timestamp: 2026-07-26T19:30:31.858557+00:00
- actor: claude-code
  id: 01kyjcvc3v8ea2r03db4mpy7h4
  text: |-
    **Corrections to the cross-repo comment above (2026-07-26).** Two things in it are now wrong:

    1. **`939nnzx` is no longer deferred.** The decision to ship single-root and not advertise `additionalDirectories` has been **reversed** — we advertise `capabilities.session.additionalDirectories: {}`. Multi-root `PathGuard` is now a blocking upstream dependency for this task, and it is in progress on the FileTool board.

    2. **The ShellPolicy claim was already stale when written, and is now doubly so.** `f1hcn7g` has been implemented upstream: `ShellPolicy` now returns `ShellPolicyOutcome` (`.allow` / `.ask(String)` / `.deny(String)`), has `remember(...)`, and ships a `ShellDecisionStore` with `decisions.yaml` beside each layer's `config.yaml`. So `session/request_permission` has its hook and `allow_always` / `reject_always` have their store — bind to those rather than to the old `String?` signature.

    **Also corrected: I previously said Shelltool's `check(workingDirectory:)` would need to accept secondary roots. That was wrong.** `ShellContext` carries no workspace root at all, and `check(workingDirectory:)` validates only `..` traversal and existence — `shell` confinement is command/environment pattern rules, not a filesystem boundary. So `additionalDirectories` needs **nothing** from Shelltool; it is a `files`/`PathGuard` concern only. The honest consequence worth carrying into the conformance: a shell command's blast radius is bounded by policy rules rather than by the workspace, and widening the workspace does not widen it. Whether `shell` should *also* be root-confined is a separate open question that ACP does not force.
  timestamp: 2026-07-27T18:19:31.323941+00:00
- actor: claude-code
  id: 01kym9dg3s8f9rjbqh364crbsd
  text: |-
    **Upstream status check, 2026-07-28 — every blocking dependency for this task is DONE and verified green.**

    **FoundationModelsFileTool** (`swift build` clean; 433 unit + 28 integration tests passing):
    - **`939nnzx` multi-root `PathGuard` — landed** (commit `70e2d34`). `PathGuard(root:workspaceRoot:additionalWorkspaceRoots:allowSymlinks:)` and `FileContext(root:additionalRoots:…)`. A path validates if it resolves within the primary root **or** any additional root. Tests cover the exact cases this task needs: path in a secondary root validates while a sibling outside all roots is rejected; **relative paths resolve against the primary root only, even when a secondary root also matches**; symlink from primary into secondary is rejected when symlinks are disallowed; overlapping/nested roots stay consistent; single-root construction is source-compatible.
    - `additionalRoots` is a **`Set<URL>`**, not an ordered collection. That is fine and does not lose anything ACP needs: order matters only for `SessionInfo.additionalDirectories` reporting, which is *our* persistence concern (see `ax6sdnt`), not PathGuard's validation concern. Note it handles the nondeterminism this could have caused — `allWorkspaceRoots` lists the primary root first and sorts the rest by path "so error messages and iteration order never depend on `Set`'s unspecified enumeration order." So violation messages are stable and golden-testable.
    - **`d7jwam5` change-set projection — landed.** `FileChangeSet` / `FileChange` with all five ACP kinds (`add`, `delete`, `modify`, `move`, `copy`) and a `patch: String` property rendering git format via `GitPatch.render(changes, relativeTo: root)`. That is ACP's diff content (`changes` array + optional `patch`) essentially ready to project.

    **FoundationModelsShelltool** (`swift build` clean; 294 tests passing):
    - **`f1hcn7g` — landed.** `ShellPolicyOutcome` is `.allow` / `.ask(String)` / `.deny(String)`, plus `remember(...)` and a public `ShellDecisionStore`. Both design calls this task pushed upstream came back answered:
      - **Scope** is exactly the recommendation: `.session` (in-memory, the non-persistent default), `.project` (`{git_root}/.shell/decisions.yaml`), `.user` (`$XDG_CONFIG_HOME/shell/decisions.yaml`) — mirroring the config layering.
      - **Match key** has a real threat model ("the threat is the over-broad key"): normalization only removes text the shell itself would not have treated as significant, handles quoting/here-docs/trailing backslashes, and stores readable command text rather than a digest.
      - So `session/request_permission` binds directly: `.ask(reason)` → the prompt, `allow_always`/`reject_always` → `remember(..., scope:)`.

    **Consequence for this task: nothing here is blocked any more.** Construct `PathGuard` from `cwd` + `additionalDirectories`, bind permission prompts to `ShellPolicyOutcome.ask`, and persist always-answers through `ShellDecisionStore`.
  timestamp: 2026-07-28T11:57:59.801469+00:00
- actor: claude-code
  id: 01kymf8mjgkr03e3y2pwyvsj0g
  text: |-
    **2026-07-28 — the profile-collision policy in this task's body is now an acknowledged stopgap, not the design.**

    Project-local config (§4) means **per-project profiles**: a repo's `.<name>/config.yaml` may name its own `profile:`, and a repo that pins a particular coding model should get it. "Warn and keep the resident model" is a limitation to report honestly, not the intended semantics.

    Filed upstream as Router **`kh01tv2`** (pooled model residency). Until it lands, keep warn-and-reuse — but surface it as a real message ("this project asks for X; the agent is running Y"), never silently.

    The underlying constraint is worth carrying into the conformance because it is sharper than the dedupe framing: **the memory budget must have exactly one authority.** Two Routers each running `runJointFit` against the whole machine budget will each conclude they can afford a large model, and together exhaust GPU memory. So multi-profile operation requires pooled, reference-counted residency with a single evictor — it is a correctness requirement, not an optimization.

    Two things already point the right way and are worth knowing when this is implemented: Router's `generationGate` lives on the **model** (`LanguageModelProfile.swift:130`) rather than the Router, precisely because MLX generation is a single non-interleavable GPU stream — so a shared model already carries the gate that keeps two borrowers correct. And `slotMembership(profile:)` (`Router.swift:394`) is the same dedupe one level down, so the generalization has a precedent rather than being novel.

    Related: Router **`ke41yth`** (per-session recording root) blocks project-local transcripts. Both upstream asks fall out of the same change — per-root configuration — so they will likely be worked together.
  timestamp: 2026-07-28T13:40:11.984026+00:00
- actor: claude-code
  id: 01kymkeb8pbdcqwydg5badhkmn
  text: |-
    **Spec audit — §1 Initialization (2026-07-28).** Walked the v2 Initialization page and the vendored `acp-v2.json` against this task. Six things were missing or underspecified; all now written up in plan §9.1 under "`initialize` — the details the peering table is too coarse for."

    1. **`info` is REQUIRED and was unspecified.** `InitializeResponse.required = ["protocolVersion", "info"]`, and `Implementation.required = ["name", "version"]` (`title` optional). The task said plenty about capabilities and nothing about identifying the agent. Report `name` as the programmatic identifier — **the product/package name, not the dotfolder `<name>`**, which is a user's private choice and does not belong on the wire — plus a display `title` and the build `version`. Clients surface all three.

    2. **Version negotiation is a behavior, not a constant.** `ProtocolVersion` is `uint16`. If we support the requested version we MUST echo it; otherwise we MUST return the latest *we* support and the client SHOULD close. Concretely, being v2-only: **a client sending `1` gets `2` back in a normal successful response — not an error.** Erroring would break the contract; the spec puts the disconnect decision on the client.

    3. **Capability markers are objects everywhere.** `PromptCapabilities` members are `PromptImageCapabilities` / `PromptAudioCapabilities` / `PromptEmbeddedContextCapabilities`; `McpCapabilities` members are `McpStdioCapabilities` / `McpHttpCapabilities`. Supply `{}` for supported, omit for not. No booleans.

    4. **`capabilities.auth` exists** (`AgentAuthCapabilities`) and we omit it. Its schema explicitly says it does *not* advertise `auth/login` / `auth/logout` — a non-empty `authMethods` does that. We have neither, so both are omitted.

    5. **Reading the client: absent = unsupported.** *"Clients and Agents MUST treat all capabilities omitted in the `initialize` request as UNSUPPORTED."* Nothing to read in stable v2 (`ClientCapabilities` has only `_meta`), but it is the same rule §8's `_meta`-negotiated elicitation gate must follow. Keep them consistent.

    6. **Ordering is enforceable.** Clients MUST initialize before creating a session, so a `session/*` call arriving before a completed `initialize` should be answered as a protocol error rather than served — serving it means acting on capabilities never negotiated.

    Also: the schema marks `capabilities` `x-deserialize-default-on-error` with `default: {}`, so an unparseable capabilities object should degrade to "supports nothing" rather than failing `initialize`.
  timestamp: 2026-07-28T14:53:13.366259+00:00
- actor: claude-code
  id: 01kymkwrky5b7j0etmgqstdyt7
  text: |-
    **Spec audit — §3 Session Setup (2026-07-28).** Five findings, all now in plan §9.1 under "Session setup — five things the peering rows do not capture."

    **1. `configOptions` is advertised at session setup, not just from `set`.** `NewSessionResponse` (`required: ["sessionId"]`) and `ResumeSessionResponse` (nothing required) both carry an optional `configOptions`. This task's config-options handling was written around `session/set_config_option`, which misses where the list is *first* published. **The `session/new` response is the primary announcement**, priority-ordered, and a client that never calls `set` still renders whatever we return there. So the model selector — the obvious first option — must be constructible **at session-creation time**, before any turn has run.

    **2. Replay uses whole-message upserts, not chunks.** Spec: replay "includes user messages, agent responses, and thoughts, each identified by unique `messageId`," and "message updates that omit `content` can update other optional fields without changing the current content." So emit `user_message` / `agent_message` / `agent_thought`, **not** the `*_chunk` variants a live turn produces — reusing the **original `messageId`s**, which is what lets a client that already saw some of them converge instead of duplicating. Replaying as chunks would pass on a lenient client, fail on a strict one, and be larger and slower than the record it derives from.

    **3. `ReplayFrom` is a cursor; `start` is one variant.** Schema: "Inclusive cursor describing where replayed session history should begin. Replay includes the position identified by the cursor," with `start` plus an `other` extension slot. We implement `start` and absent — that is all of stable v2 — but **write the replay path parameterized by cursor**, not hardcoded to replay-everything. Resuming from a message id is the obvious next variant, and a `replayAll()`-shaped function would need rewriting rather than extending.

    **4. `session/close` inherits cancellation's full semantics, including its notification.** Spec: cancel ongoing work **"as if `session/cancel` had been called"**, then free resources. That is stronger than "stop the work" — per the Cancellation section it means answering every pending `session/request_permission` with the cancelled outcome and emitting `state_update` `idle` with `stopReason: "cancelled"`. So **a close during an active turn emits that `idle` update before the close response** rather than going quiet; otherwise a client with a spinner up never learns the turn ended.

    **5. `env` and `headers` are arrays of `{name, value}`, not maps.** `EnvVariable` and `HttpHeader` are both `required: ["name","value"]`. Duplicate names are representable on the wire — pick last-wins and document it. Also `McpServerStdio` requires only `name` + `command`, `McpServerHttp` only `name` + `url`, so `args` / `env` / `headers` are genuinely optional and must not be modeled as required-but-empty.

    Confirmed unchanged: `cwd` MUSTs (absolute, session-wide regardless of spawn location, base for relative paths, part of the effective root set), resume `cwd` must match the original, `additionalDirectories` omitted-or-empty activates none, and `session/resume` is baseline for any agent supporting sessions.
  timestamp: 2026-07-28T15:01:05.790513+00:00
- actor: claude-code
  id: 01kymtptx55ssf37r86rsk4cg5
  text: |-
    **Spec audit — §6 Session Config Options + §7 Prompt Lifecycle (2026-07-28).**

    ## Config options — day one is not an empty array

    This task said "day one may ship an empty `configOptions` array." Conformant but defeatist: **one genuinely useful option needs no upstream work.** Ship a `select` in category `model` over the resident profile's **standard / flash** slots — both are already loaded, so switching between them loads nothing and specifically does **not** need Router `kh01tv2`, which is only required to switch *profiles* (models that are not resident). Put that distinction in the option's `description` so a user does not read "model" and expect the full candidate list.

    Deliberately not offered, each for a reason decided elsewhere: `model_config` context size (§4 — derived from the model, not configurable), `mode` (none exist), `thought_level` (Router has no such knob).

    **`config_option_update` is load-bearing, not decorative.** The spec names model fallback as a trigger, and Router's joint-fit really does pick among candidates by host-budget fit. When resolution lands on a different model than the selector advertises, **push an update** — otherwise the client's selector claims a model we are not running.

    Schema details worth not getting wrong:
    - **Grouping is a wrapper, not a field.** `SessionConfigSelectOptions` is ungrouped (`[SessionConfigSelectOption]`) *or* grouped (`[SessionConfigSelectGroup]`, each `required: ["groupId","name","options"]`). `groupId` names a group object, it does not tag an option. We ship ungrouped.
    - **Array order is significant** — a priority list, not a set.
    - **`set` response and the push both carry the COMPLETE set** (`SetSessionConfigOptionResponse` and `ConfigOptionUpdate` are both `required: ["configOptions"]`), never a delta.
    - Every option **MUST** have a default; categories are UX-only and "**MUST NOT** be required for correctness."

    ## Prompt lifecycle — two corrections to this task

    **1. Ordering was backwards.** This task described reporting `user_message` and then returning. The spec's sequence is: **respond `{}` first**, *then* `user_message`, then `state_update: running`, then output, then `idle` + `stopReason`. Emitting the notification before the response lets a client see an update for a prompt it has not yet had acknowledged. Also note echoing is a **MUST** — "the Agent MUST report where the user message was inserted in session history" — and a `user_message_chunk` stream satisfies it equally.

    **2. Catch the cancellation exception and map it.** The spec requires agents to "catch exceptions from aborted API calls and report the semantically meaningful `cancelled` stop reason." A Swift `CancellationError` escaping as a JSON-RPC error, or being mapped to `refusal`, is exactly the failure named. Add a test.

    **3. One prompt per session at a time.** `idle` means "ready to process a new prompt," so a `session/prompt` arriving while not idle is a client error — **not** a queue. Queueing stays composer-owned (§6.2), which is why Router's own prompt queue is deliberately not exposed over ACP. Decide the error and test it.

    **Cancellation division of labor** (reduces what we must do): the **client** SHOULD preemptively mark unfinished tool calls `cancelled` and **MUST** answer pending `session/request_permission` with the cancelled outcome. We still emit accurate terminal tool statuses, but must not block the `idle` on having done so. Ordering is a MUST: any final updates go out **before** the idle `state_update`.

    **The upsert algebra** is now written out in plan §9.1 with the spec's worked example (`[A]` + chunk `B` → `[A,B]`; then whole-message `[C]` → `[C]`). The "whole-message replaces everything accumulated, chunks included" rule is what §9.2's compaction correction and replay-convergence both depend on — implement it exactly.
  timestamp: 2026-07-28T17:00:11.557093+00:00
- actor: claude-code
  id: 01kyn12rvex6w4k704dbgeefr8
  text: |-
    **Spec audit COMPLETE — §9 Content, §10 Agent Plan, §12 Transports, §13 Extensibility (2026-07-28).** All thirteen v2 sections now walked; findings are in plan §9.1 as thirteen `####` subsections.

    **Content.** ACP's `ContentBlock` **is** MCP's — the spec says the shared structure exists so agents can "forward MCP tool outputs without transformation," which makes §8.7's content mapping shape-preserving rather than a judgement call. `resource_link` is the **only ungated** variant, so it arrives regardless of advertised capabilities: resolve `file://` inside the root set via `files`, refuse other schemes with a reason (declining to fetch an arbitrary `http://` is the *safe* answer, not just the honest one). Text support is an unconditional **MUST**.

    **Agent plan — a protocol asymmetry worth knowing even though we emit nothing.** `plan_update` is the **only** update in v2 that replaces rather than patches: agents MUST send the complete entry list and clients MUST replace entirely, *not* patch. Anyone carrying over the upsert algebra from messages and tool calls gets this backwards.

    **Transports — our stdout-purity test is asserting a protocol MUST.** Framing is UTF-8 JSON-RPC delimited by `\n`, no content-length header, and messages **MUST NOT contain embedded newlines**. "The agent MUST NOT write non-ACP content to stdout" is exactly the invariant the gated CLI test checks. Batching exists but "initialize, auth, and session operations SHOULD NOT be batched" — i.e. everything this agent handles — so it stays the wire package's concern and never becomes a sequencing hazard here.

    **Extensibility — one rule bites, and it corrects three places in the plan.** Implementations **MUST NOT** add custom fields at the root of spec-defined types ("all possible root names are reserved for future protocol versions"), so every extension goes in `_meta`, never beside it. And the underscore prefix on custom enum values is **mandatory, not stylistic**: unknown non-underscore values are reserved for future ACP variants, and implementations MUST NOT treat them as custom extensions. **Corrected in three places: MCP's lost outcome must be `_lost`, not `lost`.** A bare `lost` claims a name the protocol reserved for itself. Also: when proxying, unknown values SHOULD be preserved and unknown variants SHOULD fall back to generic UI rather than being dropped.

    **Elicitation (see also `h30sjw3`).** Sharper than "unstable-only": `elicitation/create` and `elicitation/complete` appear in the unstable meta as **method names with no `$defs` at all** — neither schema file defines a single elicitation type. Meanwhile the docs show `capabilities.elicitation: {form: {}, url: {}}` as first-class while the vendored stable `ClientCapabilities` has **only `_meta`**. The docs are ahead of the schema we generate from. Three normative rules worth carrying regardless: agents **MUST NOT** fall back to form mode when URL mode is unavailable (the tempting shortcut, explicitly forbidden — decline instead); clients **MUST** return `-32602` for an unsupported mode (so receiving it is our bug); and `elicitationId` need only be unique among **outstanding URL elicitations on that connection**, with `elicitation/complete` going **only** to the client that received the original request.
  timestamp: 2026-07-28T18:51:34.126669+00:00
depends_on:
- 01KY7EDAAEV7M16J19CESQ54ZR
- 01KY7EDW19VD4WHHX8K612FMY1
- 01KY7EDW27992S3HF62045QR29
- 01KY7EDW2P2WR8QKN8BAX6SDNT
position_column: todo
position_ordinal: '8780'
title: 'The Agent conformance: ACP methods over Router sessions'
---
Plan §9.1 (the conformance). Implements the wire package's Agent protocol over Router sessions. **Reconciled to ACP v2 on 2026-07-26 against the vendored `acp-v2.json` / `acp-v2.meta.json` — the previous description encoded the v1 turn model and would have been implemented wrong.** §9.1's peering table is the authoritative spec for this task.

Stable v2 method surface to implement: `initialize`, `session/new`, `session/resume`, `session/list`, `session/delete`, `session/close`, `session/prompt`, `session/cancel`, `session/set_config_option`, `session/update` (outbound), `session/request_permission` (outbound). `auth/login`/`auth/logout` are excused by returning no `authMethods`. `elicitation/*`, `mcp/*`, `session/fork` are unstable-schema-only and OUT of this task.

## The four things that changed from the old description

1. **`session/prompt` does not hold the turn.** It returns `{}` immediately on acceptance. Progress and completion ride `state_update` notifications: `running` → (`requires_action` when blocked on the human) → `idle` with a `stopReason`. There is no pending request to resolve. The state machine needs a named owner in the conformance.
2. **`tool_call` create is gone.** Everything is `tool_call_update` upsert semantics keyed by `toolCallId` — the first update with an unseen id IS the creation and SHOULD carry `title`. Patch rules: omitted = unchanged, `null` = cleared, value = replaced, arrays replaced wholesale. Discriminators are snake_case (`agent_message_chunk`, `in_progress`).
3. **`session/load` is gone**, folded into `session/resume` with an optional `replayFrom: {"type":"start"}` cursor. The client sends `cwd` on resume and it MUST match the original — validate against the cwd Router recorded and error on mismatch rather than silently re-rooting confinement.
4. **Modes are gone**; `session/set_config_option` + `config_option_update` replace them, with categories `mode`/`model`/`model_config`/`thought_level`. Model selection — Router's whole job — finally has a protocol-native surface. Fields: `configId`, `name`, `type` (`select`|`boolean`), `currentValue`, `category`, `options[]` (+ `groupId`). A set returns the COMPLETE option list. Every option MUST have a default. Shipping an empty `configOptions` day one is acceptable; a model selector is the obvious first entry.

## Capabilities at initialize

`capabilities` / `info` (NOT `agentCapabilities` / `agentInfo` — v2 renamed both sides). `protocolVersion: 2`. Session-scoped capabilities nest under `capabilities.session`: `prompt` (advertise `image`/`audio`/`embeddedContext` ONLY if the roster can act on them), `mcp: {stdio, http}` (§8.7), `delete` (per §5's retention decision — decided: advertise and honor), **`additionalDirectories: {}` — DECIDED 2026-07-26 to advertise, reversing the earlier do-not-advertise call.** Accept the ordered `[AbsolutePath]` on `session/new` and `session/resume`; every path absolute; invalid entries are skipped-and-logged (the schema marks the array `x-deserialize-skip-invalid-items`), never a session failure; hand the root set to `PathGuard` (upstream FileTool `939nnzx`, in progress). **The roots expand confinement ONLY** — `cwd` remains the relative-path base and stays the sole key for the config layer, the §6.1 AGENTS.md walk, and the transcript slug. **On `session/resume` the list is authoritative and replaceable**: non-empty means it is the complete resulting set, it may legitimately differ from last time, and omitted/empty means NO additional roots — never inherit the session's former roots. Note `shell` is not root-confined at all (no root on `ShellContext`; `check(workingDirectory:)` validates only `..` traversal and existence), so multi-root is a `files` concern only. Booleans are object markers (`{}`), not `true`. Stable v2 `ClientCapabilities` has only `_meta`, so expect nothing from clients.

## Session updates to emit

`user_message` (establishes the agent-owned `messageId` for the prompt), `agent_message_chunk`, `agent_thought_chunk`, `tool_call_update`, `tool_call_content_chunk`, `state_update`, `usage_update` (from `turnEnded(TokenUsage)` → `{used, size}` — this is the context meter and it is NATIVE, not an `_meta` extension), `available_commands_update`, `session_info_update` (when the auto-generated title first appears), `config_option_update`. NOT emitted: `plan_update` (no peer — Router has no planning noun; stated off honestly), `terminal_update`/`terminal_output_chunk` (real and confirmed in the schema, but a follow-up — see the new Shelltool terminal task).

## Other v2 specifics

- `StopReason`: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`, extensible via `_` prefix.
- `ToolCallStatus` gains `cancelled` and is extensible — MCP's `lost` rides as an `_`-prefixed value rather than flattening to `failed`.
- `session/cancel`: respond to every pending permission request with the cancelled outcome, stop work, then `idle` + `stopReason: "cancelled"`. Router's in-flight turn cancellation is still the gap; report "we stopped listening" honestly until it lands.
- `session/close` is a **MUST**: cancel that session's work and free resources (in-flight MCP calls, detached work, spawned stdio processes). Transcript retained.
- `session/list` is **baseline** (not capability-gated) and **cursor-paginated**; `SessionInfo` requires `cwd` and `title`, plus `updatedAt` — see the TranscriptStore task for title generation and cursors.
- `available_commands_update`: clients invoke commands as ordinary user-message text in `session/prompt`, which confirms dispatch belongs at the prompt owner. `AvailableCommandInput` requires a `type` discriminator — `{type: "text", hint: …}`.
- `session/request_permission` (outbound): `{sessionId, title, options[≥1], description?, subject?}`; subject is `tool_call` or `command`. v2 separated prompt copy from the structured subject. `PermissionOptionKind` includes `allow_always`/`reject_always` — persisting always-decisions is this package's job (stacked `ShellPolicy`); state the persistence scope.

Also unchanged from before: `session/new(cwd)` → per-cwd config layer + roster + instructions → `router.makeSession`; multi-session with the profile-collision policy (project layer naming a different model: warn, keep resident); replay from FULL history while the live session is built from the newest checkpoint (two transcripts, deliberately). Cross-repo: wire package (FoundationModelsACP), Router 46adpch (rich stream) + 8213x39 (auto-compaction) + in-flight cancellation.