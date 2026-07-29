---
comments:
- actor: claude-code
  id: 01kyfyg36h054sjbnefm5q6mam
  text: |-
    Upstream asks filed on the **FoundationModelsMCP** board 2026-07-26 (cross-repo, so not expressible as `depends_on`):

    - `4egfvw3` — **Stdio server processes: spawn, own, and kill client-supplied MCP servers.** Hard blocker for this task's stdio path. `MCPServer.connect(transport:)` takes a caller-built transport and nothing there spawns a child; the `StdioServerProcess` this plan references does not exist. Also covers killing children on `session/close`.
    - `ft5m31k` — **Expose the structured per-call record.** Blocks `rawInput` / `rawOutput` / `content` / `locations`: both `MCPServer.call(...)` and `MCPTool.call(...)` return only the elided model-facing `String`.
    - `sfben3v` — **Make terminal call outcomes public and observable (incl. `lost`).** Blocks the detached-call promise: `CallOutcome` is `private` and the only public streams are `catalogUpdates` / `progressUpdates`, whose own docs rule out reading silence as completion. Without it a detached call shows `in_progress` forever.
    - `3spcagt` — **ElicitationCoordinator: `elicitationId` + call scoping.** Not this task; belongs to `h30sjw3`.

    Also corrected in `plan.md` §8.7: there is no "transport factory" in FoundationModelsMCP. `connect(transport: any Transport)` is the seam, which is *better* for `ACPTunnelTransport` — it conforms to swift-sdk's `Transport` and needs no upstream hook.

    Note `4egfvw3` asks upstream to decide server pooling across sessions; recommendation recorded there is per-session children.
  timestamp: 2026-07-26T19:30:12.817902+00:00
- actor: claude-code
  id: 01kymkq86rt2cxy68wb74csq2z
  text: |-
    **Spec audit — §2 Authentication (2026-07-28). One rule lands on this task.**

    ACP-level auth is settled and unchanged: a local on-device agent omits `authMethods`, so `auth/login` / `auth/logout` need not exist and `auth_required` (-32000) is never raised. But **"no ACP auth" is not "no credentials"** — MCP servers are a separate axis, and an `http` server's `headers` carry real bearer tokens, supplied either by our `mcp:` config or by the ACP client in `session/new`.

    That collides with two other decisions:

    - This task requires a resumed session to **reconnect the same MCP servers**.
    - Plan §5 makes session metadata **project-local and committed to git**.

    Persisting a client-supplied `mcpServers` list to satisfy the first would write bearer tokens into a file the second commits to a shared repo. That is materially worse than anything §5's no-redaction decision weighs, because it is a **live credential**, not a dev-shaped secret in prose.

    **Rule: never persist client-supplied MCP server configurations.** There is no need — `session/resume` carries `mcpServers` itself, so the **client is the source of truth on every reconnect** and we use what we are handed. This simplifies the resume path rather than complicating it: no storage, no staleness, no reconciliation between a stored list and a supplied one.

    Config-derived servers (`mcp:` in a project `config.yaml`) are the user's own committed file and their own decision; §4's templating (`{{ env.GITHUB_TOKEN }}`) is the documented way to keep the token itself out of it.

    Verified upstream so this is not an ask: Router's `session.json` sidecar records slot, model, context, recording level, and profile — **no MCP configuration at all**. The constraint applies only to this package's own `sessions.jsonl`.

    Acceptance criteria to add:
    - [ ] Client-supplied `mcpServers` are never written to disk in any form.
    - [ ] `session/resume` reconnects purely from the `mcpServers` in the resume request.
    - [ ] A resume that omits `mcpServers` connects no client-supplied servers (config-derived ones still apply).
  timestamp: 2026-07-28T14:58:05.144260+00:00
- actor: claude-code
  id: 01kymvj3e5b20jjbv9cgks4x6k
  text: |-
    **Spec audit — §8 Tool Calls (2026-07-28). One correction to this task's permission handling.**

    **`subject: tool_call` carries a full `ToolCallUpdate`, not a `toolCallId`.** This task (and the plan row) said id. The schema is `ToolCallPermissionSubject.required = ["toolCall"]` where `toolCall` is a `ToolCallUpdate` — title, kind, status, content, locations, `rawInput`, `rawOutput`.

    That changes the design rather than just the field name: **because the request conveys the call's details itself, permission can be asked *before* emitting any `tool_call_update` for that call.** The id-only reading forces an update first so the client has something to look up — which puts a pending entry in the timeline for an operation the user may then reject. For the `destructiveHint` / `openWorldHint` gating in this task: **ask first, emit on approval.**

    Other confirmations for this task's tool-call reporting:
    - `ToolCallUpdate` requires **only** `toolCallId`. `title` SHOULD be present on the first report.
    - **`status` defaults to `pending`** when a creating update omits it — so the first update for a call that is already running must say `in_progress` explicitly, or the client renders it queued. Relevant to the detached-MCP-call path, where the first thing a client sees should be `in_progress`, not `pending`.
    - `content` and `locations` arrays **replace entirely**; `[]` or `null` clears. Use `tool_call_content_chunk` for incremental append.
    - `PermissionOption` requires all three of `optionId`, `name`, `kind`.
    - `RequestPermissionOutcome` has an `other` extension variant beyond `cancelled` / `selected` — **treat an unrecognized outcome as refusal, never as approval.**
    - `CommandPermissionSubject` requires `command` + `cwd`, with optional `toolCallId` and `terminalId`.
    - `status` / `kind` / `title` / `rawInput` / `rawOutput` are all `x-deserialize-default-on-error` — malformed fields degrade rather than failing the notification.

    Unchanged and already correct in this task: upsert keyed by `toolCallId`, first-unseen-id creates, the five statuses plus `_`-prefixed extensions (so MCP `lost` rides as a custom value), and the `ToolKind` list — note it includes `switch_mode` alongside `read`/`edit`/`delete`/`move`/`search`/`execute`/`think`/`fetch`/`other`.
  timestamp: 2026-07-28T17:15:05.029165+00:00
position_column: todo
position_ordinal: 8b80
title: 'Wire MCP to ACP: client-supplied servers, the ACP tunnel transport, and ToolCallUpdate reporting'
---
## What

See `plan.md` → **8.7 MCP wiring: two sources, three transports, two sinks**.

`FoundationModelsMCP` is the **third built-in tool** (§7.1 — files + shell + mcp, day one), so this task is not optional roster work. ACP v2 makes it load-bearing: v2 deleted `fs/*` and all five `terminal/*` client methods and redirected agents to MCP for client-side file access and execution.

§7.3's roster treats MCP servers as one catalog entry fed by an `mcp:` config section. That is half the story: **ACP itself carries MCP servers.** `session/new` and `session/resume` take `mcpServers: [McpServer]`, and the client decides which servers they run.

**Revised 2026-07-26 against the vendored `acp-v2.json`:** the v2 shape differs from what this task originally described — `type` is now a required discriminator, `sse` is removed, `args`/`env`/`headers` are optional, `session/load` is `session/resume`, and the ACP tunnel is unstable-schema-only.

## Work

**Two sources.** Compose local `mcp:` config with the client's per-session `mcpServers`. Decide and document precedence, name collisions (ACP's `name` is the `ServerIdentity`), and whether a client may override a configured server. `session/resume` carries the list too, so a restored session must reconnect the same servers. Because `sessionTools()` is async and Router's tool-instancing pipeline is synchronous, connection MUST complete **before** the tool array reaches `makeSession(tools:)` — i.e. during `session/new` / `session/resume` handling.

**Two transports in stable v2 — plus one unstable.** `McpCapabilities` has exactly `{stdio, http}`.
- **stdio** → `StdioServerProcess`. v2 shape: `{type: "stdio", name, command (absolute), args?, env?}` — field-for-field, no adapter. Advertise `capabilities.session.mcp.stdio`.
- **http** → `HTTPClientTransport`. v2 shape: `{type: "http", name, url, headers?}`, with `headers` supplying auth (authorization stays the host's job per `FoundationModelsMCP`'s decision). Advertise `capabilities.session.mcp.http`.
- **`sse` is REMOVED in v2.** There is no `McpServerSse` case to construct. (The earlier version of this task listed it — dropped.)
- **`ACPTunnelTransport` is unstable-schema-only — OUT of this task's day-one scope.** `mcp/connect` + `mcp/message` + `mcp/disconnect` live in `acp-v2.meta.unstable.json`, NOT in `acp-v2.meta.json`, and no stable-v2 capability advertises a tunnel, so a stable-only client can never ask for one. The design stands (it is an `MCP.Transport` conformance needing ACP types, and `FoundationModelsMCP` must never depend on `FoundationModelsACP`, so it belongs in this package), but it is doubly blocked: on the wire package generating the `mcp/*` payload types, and on the methods graduating to stable — and the shape may change when they do. Ship stdio + http; file the tunnel as a follow-up.

**Two sinks.** A long-running MCP call reports to both audiences: model-visible `OperationEvent` → Router's `SessionOutbox`, and user-visible `session/update` `tool_call_update`. One identity spans everything — the MCP call handle becomes `OperationEvent.correlationID`, the ACP `toolCallId`, and the `toolCallId` scoping an elicitation. A detached call stays `in_progress` across turns. v2 specifics:
- **`tool_call` create is gone.** `tool_call_update` is an upsert keyed by `toolCallId`: the first update with an unseen id IS the creation and SHOULD carry `title`. Omitted = unchanged, `null` = cleared, value = replaced; `content`/`locations` arrays replace wholesale. Use `tool_call_content_chunk` to append streaming content.
- **`ToolCallStatus` gained `cancelled` and is extensible.** So MCP's `lost` outcome rides as an `_`-prefixed implementation-specific value rather than flattening into `failed` — better than the earlier plan of burying unknown-outcome in prose (still do that too, for clients that don't understand the custom value).
- Discriminator is `in_progress` (snake_case), not `inProgress`.
- `rawInput` / `rawOutput` / `content` / `locations` need `FoundationModelsMCP`'s **structured per-call record**, not its elided model-facing string.
- `ToolAnnotations` → `ToolKind` (UI hint feeding a UI hint, never a gate). v2 kinds: `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`; custom MUST start with `_`.
- `destructiveHint` / `openWorldHint` → `session/request_permission`: where "hosts may gate on annotations" is realized. The bridge never gates; we may. v2 shape: `{sessionId, title, options[≥1], description?, subject?}` with `subject` = `tool_call` (a `toolCallId`) — note v2 separated prompt copy from the structured subject. Handle `allow_always`/`reject_always` persistence.

**Cancellation.** `session/cancel` → in-flight MCP call is blocked on Router gaining in-flight turn cancellation; even then MCP's `notifications/cancelled` is advisory, so report "we stopped listening." Also: `session/close` is a v2 **MUST** to cancel ongoing work and free resources — that includes killing spawned stdio server processes.

## Acceptance Criteria

- [ ] Config-derived and client-supplied MCP servers compose, with documented precedence and collision rules.
- [ ] `session/new` and `session/resume` both connect their `mcpServers` before tools reach `makeSession`.
- [ ] stdio and http construct correctly from their v2 config cases, including absent `args`/`env`/`headers`.
- [ ] `McpCapabilities` (`capabilities.session.mcp`) is advertised at `initialize` and matches what is actually supported — stdio and http only.
- [ ] MCP call lifecycle drives `tool_call_update` upserts with correct `status` transitions, including a detached call remaining `in_progress` across turns.
- [ ] `toolCallId` equals the MCP call handle equals the `OperationEvent.correlationID`.
- [ ] `kind` and `locations` are populated; annotation-based permission gating works.
- [ ] `session/close` terminates spawned stdio server processes.
- [ ] NOT in scope: `ACPTunnelTransport` (unstable schema — separate follow-up task).

## Tests

- [ ] A client-supplied stdio server is spawned, connected, and its tools appear in the session.
- [ ] A config server and a client server with the same `name` resolve per the documented rule.
- [ ] `session/resume` reconnects the same servers.
- [ ] A first `tool_call_update` with an unseen `toolCallId` creates the call client-side; a later partial update patches only the named fields.
- [ ] A detached MCP call emits `in_progress`, then a terminal status on a later turn, with a stable `toolCallId`.
- [ ] A lost MCP connection reports an `_`-prefixed lost status with unknown-outcome wording, and degrades to readable text for a client that ignores it.
- [ ] A `destructiveHint` tool triggers `session/request_permission` before the call; denial prevents it; `reject_always` persists.
- [ ] `locations` are populated from a `.resourceLink` result.
- [ ] `session/close` leaves no orphaned server processes.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.