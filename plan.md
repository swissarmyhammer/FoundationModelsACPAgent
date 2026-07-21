# Plan: FoundationModelsACPAgent — the composed agent over the harness

> **Created 2026-07-21**, split out of FoundationModelsACP the same day it was
> reborn there: the wire and the composition are separate packages. Sibling
> [`../FoundationModelsACP`](../FoundationModelsACP/plan.md) is the pure,
> zero-dependency ACP wire (generated types, role protocols, connections,
> ndJSON); **this package is the agent** — it layers over
> FoundationModelsAgentHarness and FoundationModelsRouter and adds
> slash-command support and configuration. Everything the harness
> deliberately refuses to own — file I/O, dotfolders, command registries,
> the roster, the `Agent` conformance — lives here.

## Layering

```
editors (Zed, …) ──ndJSON/stdio──┐          CLI / Mac app (thin frontends,
                                 │           consume the composition directly)
                                 ▼                        │
                    FoundationModelsACPAgent  ◄───────────┘
                    │  config (Extras: DotfolderStack + TemplateEngine, §4)
                    │  AGENTS.md assembly (Extras: AgentsMd, §6.1)
                    │  slash commands + registry + dispatch (§6.2)
                    │  tool roster: config sections → real tools (§7)
                    │  transcript location policy (§5)
                    │  HarnessACPAgent: the Agent conformance (§9.1)
                    ▼
   FoundationModelsACP (the wire: types, role protocols, connections — zero deps)
   FoundationModelsAgentHarness (the loop: tokens, compaction, events)
                    ▼
   FoundationModelsRouter (models, sessions, recording, restore, compact)
                    ▼
   FoundationModelsExtras (stack, templating, SlashCommand, AgentsMd, LayeredYAMLDocument)
```

Dependencies: the ACP wire, the harness, Router, Extras, and the tool
packages the roster names (`FoundationModelsFileTool`,
`FoundationModelsShelltool`, `FoundationModelsMCP`, …). Naming tool packages
is *this* package's job precisely because the harness may not: nothing
cycles, since no tool package (and not the agents tool) ever depends on it.

The composition, end to end:

```
config  (dotfolder stack, §4)
  → ProfileDefinition → Router.resolve → resident profile
  → tools         (roster §7: config sections → constructed, confined tools)
  → instructions  (builtin prompt + AGENTS.md §6.1 + config replace/append)
  → compaction    (coding-tuned CompactionPrompt + TokenBudget)
  → Harness(router:tools:instructions:compaction:)      ← the reusable loop
  → HarnessACPAgent(harness:commands:)                  ← §9.1, + registry §6.2
```

## Decisions

- **This package is the composition layer** — supersedes "the product layer
  awaits a home" and the interim ideas of a raw adapter directly over
  Router (commands and config had no source there) and of housing the
  composition inside the wire package (split out: the wire's consumers
  shouldn't drag in MLX, Yams, Stencil, and tool packages to decode a
  `SessionUpdate`). The noun test lands three ways: session storage/restore
  nouns are Router's, turn/loop nouns are the harness's, and commands +
  configuration + the conformance are this package's. Because the
  conformance composes `Harness`/`HarnessSession`, every loop behavior
  (auto-compaction, budgets, retry, correlated events) works over ACP with
  zero wire-specific code.
- **Slash-command dispatch lives at the prompt owner.** The prompt owners
  are this package's `prompt()` handler and the frontends' composers; each
  routes a leading `/name` through the registry before anything reaches the
  model — a `/compact` typed in an editor must **never** become a model
  prompt. Registry mechanics (merge, precedence, near-miss matching,
  `commandUpdates` re-publication) live here; the cross-package
  *vocabulary* (`SlashCommand`/`SlashCommandProviding`) stays in Extras.
- **Builtin commands bind to session surface**: `/compact` →
  `session.compact()`, `/context` → usage/fill, `/status` → session
  id/cwd/model, `/help` → the registry. Dotfolder template commands
  (`commands/*.md`) load here (Extras stack + untrusted Stencil) as
  `.prompt`-only; `.action` requires linked Swift — the trust boundary
  travels intact.
- **Configuration is this package's** (§4): the dotfolder name, the
  `AgentConfiguration` schema (`profile` with standard/flash/embedding
  slots, `tools` built-in + `mcp`, `instructions`, `recording`,
  `transcripts`, `compaction`), defaults directory, template-first
  rendering, and the mapping onto Router types. The harness never sees any
  of it — it receives values.
- **Loading is Extras'.** `LayeredYAMLDocument` (Extras plan §11) loads →
  renders (trusted defaults, untrusted user/project) → merges with the
  family's one rule → returns a value tree with per-key source tracking;
  this package decodes it via `Codable`.
- **The built-in roster is linked packages under well-known names.** One
  reserved config section per tool: `files:` (FoundationModelsFileTool),
  `shell:` (FoundationModelsShelltool), later `codeContext:`, `multitool:`,
  `skills:`, `agents:`. Presence enables; the section body decodes as
  **that package's own option type**. Unknown top-level sections warn; MCP
  is the escape hatch for tools we don't link. This is the pre-pivot
  `ToolCatalog` "add tools here and only here" location, relocated to the
  one package allowed to name tool packages.
- **MCP transport is FoundationModelsMCP's job, not ours.** Config `mcp:`
  entries carry either `command` (+args/env — the MCP package spawns and
  owns the stdio subprocess) or `url` (http/s client connect); this package
  passes the entry to `MCPToolProvider` and receives `[any Tool]`. Process
  lifecycle, reconnects, and pooling across sessions are upstream asks on
  FoundationModelsMCP.

---

> The sections below carry their numbering (§4–§10.1) from the pre-pivot
> harness plan's product-layer extraction, via the FoundationModelsACP
> rebirth — renumber in a later editing pass. Where prose says "the harness"
> doing composition-flavored work, read "this package". `§9.2` references
> point at the wire spec, now `../FoundationModelsACP/plan.md`.

## 4. Configuration

### The pluggable dotfolder

The frontend passes a bare name (no dot). `DotfolderStack` — **Extras'** type
now (moved out of this package so the whole family layers files one way;
Shelltool's stacked `ShellPolicy` is the candidate second adopter). Shipped as
`init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)` —
`userDirectory` and `environment` are injectable so tests and demos never
touch the real home — it derives the locations and the precedence order:

1. **Builtin defaults** — a *directory of real files*, never compiled-in
   content (the swissarmyhammer lesson: embedded builtins meant a recompile to
   edit markdown — Extras plan §1). A curated coding-model profile that works
   out of the box on a 16 GB machine (`recording.level: full`,
   `transcripts.location: home`), materialized on first run, with a
   `<NAME>_DEFAULTS_DIR` override so development edits never involve a build.
2. **User layer** — XDG, as Extras shipped it: `$XDG_CONFIG_HOME/<name>/config.yaml`
   when that variable is set and absolute, else `~/.config/<name>/config.yaml`
   (machine-wide preferences; bare `<name>` under a config dir — the
   hidden-file dot convention doesn't apply there).
3. **Project layer** — `$CWD/.<name>/config.yaml` (per-repo overrides; `$CWD` here is
   the agent's working directory, not the process cwd).

Missing files are fine; a present-but-malformed file is a hard, early error naming the
file and line (never silently fall back over a typo'd config). Merge semantics are
**key-level override**: scalars and arrays replace wholesale when the later layer
defines them; sections merge by key. Wholesale array replacement matches the family's
full-replace override rule (Skills' `FolderStack`) and keeps "which models am I
running?" answerable by reading one file.

**Every dotfolder document is a template first.** Before decoding, each file
renders through Extras' Stencil-backed `TemplateEngine`: `{{ variables }}`
from a provided `TemplateContext`, env vars, and well-known values (dotfolder
name, cwd, date) on the swissarmyhammer ladder (context > env > well-known),
plus `{% include %}` partials from the stack's `_partials/` (nearest layer
wins). Defaults render *trusted*; user/project layers *untrusted* (validated,
side-effect-free — no filesystem or exec capability — and metered, as built:
include-depth, loop-iteration, and output-size budgets). One rule
for every format — config YAML, command templates and frontmatter (§6.2),
instructions and memory (§6.1): **render the whole file, then parse**, so
even frontmatter values can be templated.

### Schema (v1)

```yaml
# ~/.config/<name>/config.yaml  or  <project>/.<name>/config.yaml
profile:
  name: coding                    # optional; defaults to the dotfolder name
  standard:                       # candidate lists, biggest-first, "org/repo@rev"
    - mlx-community/Qwen2.5-Coder-32B-Instruct-4bit
    - mlx-community/Qwen2.5-Coder-14B-Instruct-4bit
    - mlx-community/Qwen2.5-Coder-7B-Instruct-4bit
  flash:
    - mlx-community/Qwen2.5-Coder-3B-Instruct-4bit
  embedding:
    - mlx-community/bge-small-en-v1.5-4bit

tools:
  files: {}                       # well-known built-ins (§7): presence enables;
  shell:                          #   the body decodes as that tool package's
    policy: strict                #   own option type
  mcp:                            # MCP servers — FoundationModelsMCP owns the
    - name: github                #   transport: `command` spawns a stdio
      command: ["npx", "-y", "@modelcontextprotocol/server-github"]
      env: { GITHUB_TOKEN: "{{ env.GITHUB_TOKEN }}" }   # templated (untrusted layers)
    - name: internal-docs
      url: https://mcp.example.com/sse                  # http/s client connect

recording:
  level: full                     # off | metadata | full → Router's RecordingLevel

transcripts:
  location: home                  # home | project | /absolute/path   (§5)

instructions:
  replace: |                      # optional: swap out the builtin system prompt
    You are a code-review assistant. # entirely — this text becomes the base
  append: |                       # optional: extra text appended after the base
    Prefer swift-testing over XCTest.   # (the builtin prompt, or replace: if set)
```

Everything maps 1:1 onto existing Router types (`ProfileDefinition`, `ModelRef`'s
`"org/repo@rev"` Codable form, `RecordingLevel`) — the config layer is a codec, not a
model. Unknown top-level keys warn (forward compatibility for tool sections, §7.3);
unknown keys *inside* known sections are errors (typo protection).

**System prompt: a clear, published artifact.** The builtin coding instructions are
not a hidden string — and not a compiled-in one either: they ship as
`Instructions.md` in the defaults directory (layer 1 above; editable like any
file), reproduced verbatim in DocC/README, and surfaced at runtime
(`Harness.instructions` exposes the fully assembled prompt; the CLI prints it with a
flag) — so users always know exactly what `replace:` is replacing. Assembly is:
base = `instructions.replace` if set, else the builtin prompt; then the
session's memory files (user then project — §6.1); then `instructions.append`
last. Each config key follows the normal layer rules independently — a
project-layer `replace` overrides a home-layer `replace` wholesale, and
`append` composes with whichever base won.

**Context size is deliberately not configurable.** It is derived from the model
automatically: Router already fetches each candidate's HF `config.json` during
sizing, which carries the model's native maximum (`max_position_embeddings`), and its
joint-fit already prices KV-cache-per-context against the host budget. Deriving
context where that metadata already lives is a small upstream change (§8, item 2);
users pick models, the system picks the context they can afford.

`AgentConfiguration` is `Codable + Sendable + Equatable`, constructible in
tests without any file I/O. Loading is Extras' `LayeredYAMLDocument` over the
stack (decision 1b, head): locate → render → merge with the family's one
rule, per-key source tracking — Extras remains the only thing that touches
disk, and merge semantics are written exactly once family-wide.

## 5. Transcripts: where recordings live

**Decision: home, keyed by project — `~/.config/<name>/transcripts/<project-slug>/`,
under the stack's user-layer root (XDG-derived, §4) — with a
config escape hatch.** Consulting Router settled it:

- Router's layout is `<recordingsDir>/<routerId ULID>/…` with a fresh router id per
  run. In a *project-local* dotfolder that means an ever-growing pile of opaque ULID
  directories accumulating in every repo you ever pointed the agent at, each needing
  `.gitignore` protection. In one home location it's just history.
- The stated requirement is that the Mac app and the CLI **share** transcript
  recording. The app's session browser wants to enumerate *all* projects' sessions
  from one root ("what was I doing in repo X last week?"). One home root makes that a
  directory walk; per-project storage makes it a filesystem-wide hunt.
- Transcripts at `RecordingLevel.full` contain complete prompts, file contents fed to
  tools, and model output. That is exactly the class of artifact that must never ride
  along in a repo — gitignored or not (archives, `git add -f`, backup tools).
- Transcripts must survive the repo. Deleting a checkout shouldn't delete the record
  of what the agent did to it.

Layout — the harness owns the two segments above Router's root, Router owns everything
below, unchanged:

```
~/.config/<name>/transcripts/
    -Users-wballard-github-swissarmyhammer-FoundationModelsRanker/    # project slug (see below)
        01K3F.../                                      # routerId — Router's layout from here
            manifest.json
            sessions.jsonl
            01K3G.../transcript.jsonl
```

The **project slug** is the agent's working-directory absolute path with `/` → `-`
(the Claude Code projects convention): human-readable, collision-free in practice,
reversible enough for a browser UI to show real paths.

`transcripts.location` overrides: `project` puts the same layout under
`<project>/.<name>/transcripts/` (no slug segment; the harness then writes a
`.gitignore` of `*` + `!.gitignore` into the dotfolder, the Shelltool/CodeContext
convention) for users who want self-contained repos; an absolute path wins outright.

`TranscriptStore` also exposes the read side both frontends need:
`sessions(inProject:)` / `allProjects()` returning lightweight `Codable` summaries
(built from `sessions.jsonl` + `manifest.json`), and
`transcript(for sessionID:) -> [Transcript.Entry]` via Router's `TranscriptTree`
reconstruction. Session *restoration* into a live session already exists upstream
(`RoutedLLM.restoreSessionTree`) — the store just locates the directory to feed it.

The ownership boundary, stated plainly: **`TranscriptStore` never records and
never restores.** It owns exactly three things — the root location policy, the
project slug scheme, and lightweight browse summaries (read via Router's own
readers). Everything that gives a `transcript.jsonl` its meaning — writing
events, reconstructing entries, applying compaction checkpoints, rebuilding a
live session — is Router's, and the harness calls Router to do it.


### 6.1 Agent-instructions files — AGENTS.md via Extras' `AgentsMd`

*(Reframed 2026-07-21: these are **not memory files** — per
[agents.md](https://agents.md/), `AGENTS.md` is "a README for agents,"
context and instructions. Nothing here remembers anything across sessions.
The discovery walk itself is now Extras' fourth pillar, `AgentsMd` — Extras
plan §10 — because FoundationModelsAgents needs the identical walk for
sub-agent instructions; this layer just consumes it.)*

The single highest-leverage feature of the tools this product emulates is an
agent-instructions file read before doing anything. Resolution is **per
session, relative to its working directory** — never per process — so ACP's
`session/new(cwd)` and a multi-window app get the right context per
conversation automatically.

At session creation, this layer assembles two sources:

1. **User-level** — `~/.config/<name>/AGENTS.md` via
   `DotfolderStack.content("AGENTS.md")` (machine-wide; our extension — the
   spec itself has no home-directory concept), prepended most-general-first.
2. **Project-level** — `AgentsMd.documents(from: cwd)`: the walk from the
   repository root down to the session's cwd, reading at each directory the
   first of `AGENTS.md`, `AGENT.md` (the spec's migration alias),
   `CLAUDE.md` (ecosystem-compatibility alias), one file per directory,
   outermost-first so nearest-to-cwd lands last — the spec's "closest one
   takes precedence."

Assembly order (completing §4's picture): base prompt (builtin or
`instructions.replace`) → user-level file → project-level documents
(root → cwd) → config `instructions.append`. Each file is delimited by a
header naming its absolute path, so both the model and anyone reading the
session's `instructions` (the published-artifact contract, §4) can attribute
every line. Missing files are simply absent; a present-but-unreadable file is
a logged warning, not the hard error config files get — this is content, not
configuration. Each document renders through Extras' template engine
(untrusted, §4) before assembly, so partials and env vars work in AGENTS.md
exactly as they do in command templates.

The assembled text is read once at session creation, folded into the
`instructions` value handed to the harness constructor, and pinned for the
session's lifetime — a new session picks up edits. Instructions are never
folded by compaction (Router compaction plan §1.3 invariants), so this
context survives every fold by construction. The harness never knows any of
this happened; it just receives longer instructions.

### 6.2 Slash commands — one registry, three sources

Slash commands are a session-level noun: `/compact` acts on *this* session,
and a skill discovered in *this* repo becomes a command in *this* session
only. So the registry lives on `HarnessSession`, assembled at session
creation like tools and memory, and re-published when a source changes.

**The cross-package currency is Extras' `SlashCommand`**: `name` /
`description` / `argumentHint` plus a two-kind `Body` — `.prompt(template:)`
expands into an ordinary model turn; `.action` runs code and streams text,
never touching the model. Contributors implement `SlashCommandProviding`
(`commands(workingDirectory:)` + optional `commandUpdates` stream) against
the leaf, never the harness — the dependency diamond keeps arrows pointing
only downward.

Three sources, merged in precedence order (later wins on name collision,
logged; builtin names are reserved and never overridden):

1. **Builtins** — harness `.action` closures capturing the session:
   `/compact` (force compaction now), `/context` (fill, tokens, resolved
   context), `/memory` (print `Harness.instructions` with source headers —
   §4's published artifact, interactive), `/status` (session id, cwd,
   model/profile, transcript path), `/help`. Frontend verbs (`/quit`,
   clear-as-new) stay out — composer affordances, same rule as queueing.
2. **Linked providers** — `SlashCommandProviding` conformers registered by
   catalog roster entries (§7.1): the *code-backed* lane. Only linked Swift
   can construct `.action` — the trust boundary; in-process code is already
   trusted as tools. Skills is the flagship future conformer (one `.prompt`
   command per discovered skill, pushed via `commandUpdates` as files
   change). Day one ships the seam, not a conformer.
3. **Dotfolder templates** — the *data* lane: frontmatter markdown in
   `~/.config/<name>/commands/*.md` and `<project>/.<name>/commands/*.md`, rendered
   whole through Extras' Stencil engine (untrusted — §4) and parsed into
   `.prompt`-only commands. Data can never become `.action`: a broken or
   malicious template at worst yields a bad prompt under normal tool
   confinement. Layers user < project, like config. (MCP prompts are the
   reserved fourth source: `prompts/list` + `listChanged` feed this same
   registry when the MCP roster entry lands — finally consuming ACP's
   `mcpServers`.)

**Dispatch lives at the prompt owner** — this package's `prompt()` handler
for the wire, and the frontends' composers for direct consumption (the old
"dispatch lives in `run()`" died with the harness re-scope: the loop no
longer knows commands exist, and a `/compact` typed in an editor must never
reach the model as a prompt). A leading `/name` routes through the registry
*before* anything touches the session: `.prompt` expands (template +
arguments) into a normal recorded turn; `.action` streams output with **no
model turn and no transcript entries** beyond what the action itself records
(`/compact` its `CompactionSegment`; `/help` nothing). Unknown `/name`
errors with near-matches — never a model turn; frontends escape a literal
leading slash. Registry mechanics (merge, precedence, near-miss matching,
`commandUpdates` re-publication) are this package's; the vocabulary is
Extras'.

On every registry change: `HarnessState.availableCommands` updates (CLI
autocomplete, app palette) and the ACP conformance fires
`available_commands_update` (§9.1) — the protocol noun this registry peers
with.


## 7. Tools

### 7.1 The catalog — the well-marked follow-up location

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the single
place tools are registered — the well-known names for our well-known tools
(head decision): each linked package gets one reserved config section, and
adding a tool is a dependency plus one catalog line:

```swift
/// The harness tool catalog.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW TOOLS HERE — and only here.
///   1. Put the implementation in Tools/<Name>/.
///   2. Append its constructor to `builtin(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in the harness needs to change.
/// ══════════════════════════════════════════════════════════════════
public enum ToolCatalog {
    public static func builtin(context: ToolContext) -> [any FoundationModels.Tool]
}
```

`ToolContext` carries what every tool needs (working directory, the event-emitter for
`ObservedTool`, the flash handle) so tool constructors stay uniform. Frontends may
append their own tools: `Harness(..., extraTools: [any Tool])`.

Catalog entries are also where slash-command providers register (§6.2): an
entry may pair its tool with a `SlashCommandProviding` conformer (from
`FoundationModelsExtras`) and the catalog feeds it into the session's command
registry. The direction rule is absolute — tool packages conform to the
*leaf's* protocol; nothing outside this package ever names a harness type.


### 7.3 The tool roster (composed as each package ships)

Each tool is one catalog entry plus (usually) one dependency. Reserved config
section names keep the schema forward-compatible (§4):

| Tool | Source | Blocked on | Config section |
|---|---|---|---|
| `files` | `FoundationModelsFileTool` (**built**) — first builtin entry, in v1 | nothing | `files:` |
| `shell` | `FoundationModelsShelltool` (**built**) — second builtin entry, in v1 | nothing | `shell:` |
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | thin `Tool` shim over `CodeContext` — explicitly left to consumers | nothing; first follow-up | `codeContext:` |
| MCP servers | `MCPToolProvider` | nothing; needs config for server commands | `mcp:` |
| `runCode` | `MultiTool` (JS composition over the catalog) | nothing | `multitool:` |
| skills / sub-agents | FoundationModelsSkills / FoundationModelsAgents | those packages (plan-only) | `skills:` / `agents:` — Skills also contributes dynamic `/skill-name` slash commands via `SlashCommandProviding` (§6.2) |


## 9. Frontends: the shared-consumption contract

Three consumers share the harness: the Mac app, the CLI, and **any ACP client**
(Zed, editors — §9.1). The app and CLI are out of scope to *build* here, but every
contract is in scope to *prove*:

- Both construct **this package's composed agent** with the **same dotfolder
  name** — that single string is what makes config and transcripts shared.
  The name is chosen by the frontend, not baked into any layer below.
- The CLI is a thin ArgumentParser wrapper: parse args → construct agent → render the
  `HarnessEvent` stream to the terminal. `Examples/HarnessDemo` *is* this CLI in
  miniature and doubles as the living contract test; the production CLI likely grows
  in its own repo from a copy of it.
- The Mac app binds `HarnessState` and `ResolutionProgress` to SwiftUI and uses
  `TranscriptStore.allProjects()`/`sessions(inProject:)` for its history browser.
- **Sandboxing decision:** sharing `~/.config/<name>` and `$CWD/<anywhere>` is incompatible
  with the App Sandbox. Recommendation: the Mac app ships **non-sandboxed** (a
  developer tool operating on arbitrary repos — the norm for this product class; it
  can still be notarized and hardened-runtime). If sandboxing ever becomes mandatory,
  the fallback is security-scoped bookmarks per project plus moving the home layer to
  `~/Library/Application Support/<name>/` with the CLI honoring the same path — the
  `DotfolderStack` seam localizes that change. Decide before the app ships; nothing in
  the harness blocks on it.

### 9.1 ACP: this package's agent composes the harness

`HarnessACPAgent` — this package's `Agent` conformance — composes `Harness`/
`HarnessSession` with the config, roster, and command registry from §§4–7.
ACP is an **application protocol** — its nouns (cwd sessions, prompt turns,
visible tool calls, stop reasons, session management, available commands)
are owned across the stack this package assembles, and a wire protocol
attaches at the layer that owns its nouns (a language *server* speaks LSP; a
parser doesn't). The lower layers never pretend to be agents: the harness
stays a wire-free loop, `RoutedSession` stays Router's session surface,
`LanguageModelSession` stays Apple's conversation primitive.

**The wire layer is this package's first target** (`FoundationModelsACP`):
generated schema types (vendored v1.19.x), the `Agent`/`Client` role
protocols, the `*SideConnection` full-duplex runtime, ndJSON framing — zero
dependencies, spec'd in §9.2.

**Explicit peering — harness nouns ↔ ACP nouns.** The conformance
(`HarnessACPAgent`, in this package's agent target) is a
*translation, not a construction*: every ACP concept names its harness peer,
and anything with no peer is a capability switched off honestly, never faked.

| ACP noun | Harness peer |
|---|---|
| the agent behind the connection | `Harness` — `initialize` reports its capabilities: text prompts, session management on; the harness never issues `terminal/*` or `fs/*` in v1 (tools run in-process, below; terminals are a *client* capability the harness simply never exercises) |
| session (`sessionId`, cwd, `mcpServers`) | `HarnessSession` — `session/new(cwd)` ⇒ `harness.newSession(cwd:)`; project config layer, §6.1 memory, tool confinement, and transcript slug are already keyed off that cwd; `mcpServers` is accepted-and-ignored in v1 (logged, documented) |
| `session/prompt` (long-lived request) | `HarnessSession.run(prompt)` — one turn; the pending request resolves at turn end with a `StopReason` |
| `session/update` notification stream | the `HarnessEvent` stream, mapped 1:1: `textDelta` → `agent_message_chunk`, `reasoningDelta` → `agent_thought_chunk`, `toolCall(id:)` → `tool_call`, `toolStatus(id:)` → `tool_call_update` — `ToolCallID` *is* the wire `toolCallId` (§6) |
| `StopReason` | the turn's disposition: completed → `end_turn`, guardrail refusal → `refusal`, `cancel()` → `cancelled` |
| `available_commands_update` | the session's slash-command registry (§6.2) — published at session start and re-published whenever a source changes (skill discovered, template edited); invoked commands arrive as `session/prompt` text and dispatch inside `run()` like every frontend's |
| `session/cancel` (notification) | `HarnessSession.cancel()` — the still-open prompt request resolves with `cancelled`, possibly after final updates |
| `session/list` / `load` / `resume` / `delete` | `TranscriptStore.sessions(inProject:)` + Router restore. **Replay comes from Router's full recorded history** (the conversation the user actually had); **the live session is constructed from the newest compaction checkpoint** (the model's working transcript) — two different transcripts, deliberately. Restore reassembles the harness side (config layer, memory, confinement) from the cwd recorded at handle minting (§8) |
| `session/close` | `Harness` drops the `HarnessSession` from its bookkeeping — recording handle closed, transcript retained on disk (the v2 RFDs make this baseline alongside list/resume, below) |
| `authenticate` / `logout` | no peer — a local on-device agent has no auth; capability off, method-not-found, and the `authRequired` error (-32000) is never raised |
| session config options | no peer in v1 — capability off (may earn a peer later; typed config values are v2-baseline material) |
| session modes (`session/set_mode`) | never — deprecated wire-side in favor of `set_config_option`; the conformance answers method-not-found and no mode support is planned |
| `fs/*`, `terminal/*`, `session/request_permission` | no peer in v1 — tools run in-process (below) |

Because ACP turns go through `run()`, everything §6 owns works over ACP with
zero ACP-specific code: compaction (proactive and reactive), recording sync,
memory, confinement, the context meter. `HarnessState` has no peer — a
frontend affordance ACP clients replace with their own UI — and queueing stays
composer-owned (§6). (Name note: the inlined target declares the protocol-role
`Agent`; Harness-first naming means nothing else is named `Agent`, so
`HarnessACPAgent: Agent` reads unambiguously.)

Practical decisions:

- **The production CLI and the ACP agent are the same binary** — `<cli> acp` speaks
  ndJSON over stdio (stdout sacred, logs to stderr — §9.2's framing rules). One more
  reason the CLI stays thin: all three frontends are renderers over the same engine.
- **v1 supports multiple concurrent ACP sessions.** One-resident-profile
  constrains *loaded models*, not session count: `HarnessSession`s keyed by
  `sessionId`, each with its own cwd-derived config layer, memory,
  confinement, and slug; turns serialize at the model's `serialGate`;
  recording stays per-session via per-session handles (§8).
  **Profile-collision policy:** a project layer naming a different model than
  the resident profile logs a warning and keeps the resident model; the rest
  of the layer is honored. Gate waits are `Task`-cancellation-aware, so a
  queued session's `session/cancel` never outwaits another session's turn.
- **Tools stay in-process in v1 — an accepted, visible risk.** ACP routes file
  access through the client (`fs/*`, `session/request_permission`); ours hit
  the local filesystem directly — workable while agent and client share a
  machine, but unusual for an in-editor ACP agent, so recorded as an accepted
  risk (PathGuard/ShellPolicy confine the blast radius). The seam is
  `ToolContext`, which can later carry an ACP-backed filesystem/permission
  environment — a follow-up, gated on need.
- **stdout purity is tested, not assumed.** The `shell` tool runs subprocesses
  in-process while stdout must carry nothing but ACP frames; a gated integration
  test runs `<cli> acp`, executes a real shell-tool turn, and asserts every stdout
  byte parses as ndJSON (§10).

**Superseded: the `SessionProvider` design** — an external bridge driving the
inner bare session through a provider (factory + store hooks + `onTurnEnded`
sync). It failed on four counts, all symptoms of attaching an application
protocol at the model layer: a **stale session** after every compaction swap
(the session was handed over by value, once); **compaction never triggering**
on ACP turns (fill check and retry live in `run()`); a bolt-on turn-end
recording hook; and `session/load` **replaying the compacted transcript**
instead of the user's real history. All four dissolve with the agent-level
conformance; none of the provider machinery gets built.

Tailwind worth noting: the **ACP v2 RFDs** (active as of 2026-07-02) make
`session/list` / `resume` / `close` *baseline* and fold `session/load` into
`session/resume` with `replayFrom` cursors — i.e., the protocol is converging on
exactly the session model the peering table already provides (`TranscriptStore` +
Router's checkpoint-aware restore), so the conformance is an investment in the v2
direction, not v1-only plumbing.

### 10.1 Evaluations — `PythonCLIEvaluation` (end-to-end coding agent)

*(Moved here 2026-07-21 from the harness plan: this eval drives real `files`
+ `shell` tools, and no tool package may be referenced in the harness
package — the harness keeps a compaction-focused eval over sample tools
instead. This one belongs to the layer that composes the roster.)*

**`PythonCLIEvaluation` (files + shell, end to end).** Drives both core
tools through a real multi-turn build task, on Apple's Evaluations framework
(swift-testing native), gated on Apple silicon + real models + network:

1. **Subject**: `subject(from sample:)` creates a **fresh temp workspace** —
   the session's `workingDirectory` and the tools' confinement root — wires
   recording into a temp location, constructs the composed agent with real
   `files`/`shell` tools and the coding instructions, runs it to completion
   on the sample's prompt, and returns a result carrying the workspace path,
   the transcript, and run stats.
2. **Dataset**: `ArrayLoader` of `ModelSample`s — each prompt a variant of
   "build a small Python CLI" (`pyproject.toml`, at least one third-party
   package such as `click`, the CLI, pytest tests, a project-local venv,
   pytest green, then run it), with `expected` carrying the fixed
   input/output pair the finished CLI must satisfy. Start with 20–30
   hand-written samples per Apple's guidance; scale later with
   `SampleGenerator`.
3. **Quantitative `Evaluator`s — mechanical, re-verified outside the agent**
   (never trusting the transcript's claims), one `Metric` each, returning
   `.passing()`/`.failing()` with rationales: `PytestGreen` (the evaluator
   re-runs `pytest` in the venv itself, exit 0), `CLIRuns` (executes the CLI
   itself against `sample.expected`'s fixed input and checks the output),
   `FilesPresent` (expected files exist), and `ToolTraffic` (the transcript
   contains both `files` and `shell` tool calls).
4. **Aggregation and target**: `MetricsAggregator.computeMean` per metric;
   the `@Test` asserts mean pass rates against thresholds. Turn count,
   tool-call counts, and token usage ride along as scored values, keyed by
   the resolved model from `manifest.json`.

Isolation rules: everything happens inside the temp workspace — venv within
it, no system-Python mutation, no network beyond package install; the
workspace is deleted after grading (transcripts retained for failed runs).

