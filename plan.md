# Plan: FoundationModelsACPAgent — the composed agent over the Router runtime

## 1. What this package is

The wire and the composition are separate packages. Sibling
[`../FoundationModelsACP`](../FoundationModelsACP/plan.md) is the pure,
zero-dependency ACP wire: generated types, role protocols, connections, ndJSON
framing. **This package is the agent.** It layers over **FoundationModelsRouter**
— the family runtime, whose sessions are self-folding
(`makeSession(budget:compactionPrompt:)`), token-metered, event-streaming with
correlation ids, and recorded — and owns everything the runtime deliberately
refuses to own: file I/O, dotfolders, the command registry, the tool roster, and
the `Agent` conformance, named **`RoutedACPAgent`**.

```
editors (Zed, …) ──ndJSON/stdio──┐          CLI / Mac app (thin frontends,
                                 │           consume the composition directly)
                                 ▼                        │
                    FoundationModelsACPAgent  ◄───────────┘
                    │  configuration (§2)
                    │  Instructions.md + AGENTS.md assembly (§3)
                    │  transcript location policy (§4)
                    │  tool roster: config sections → real tools (§11)
                    │  slash commands: registry + dispatch (§14)
                    │  RoutedACPAgent: the Agent conformance (Part II)
                    ▼
   FoundationModelsACP (the wire: types, role protocols, connections — zero deps)
                    ▼
   FoundationModelsRouter — the runtime: models, sessions (self-folding,
                    │      token-metered, event-streaming, recorded), restore
                    ▼
   FoundationModelsExtras (DotfolderStack, TemplateEngine, SlashCommand, AgentsMd, LayeredYAMLDocument)
```

**Dependencies.** The ACP wire, Router, Extras, and — day one, not eventually —
the four sibling packages of the built-in roster: **`FoundationModelsFileTool`**
(`files`), **`FoundationModelsShelltool`** (`shell`), **`FoundationModelsMCP`**
(`mcp`), and **`FoundationModelsSkills`** (its slash-command half; §14.2). Naming
tool packages is *this* package's job precisely because the runtime may not.
Nothing cycles: no tool package ever depends on this one.

**The composition, end to end:**

```
config  (dotfolder stack, §2)
  → ProfileDefinition → Router.resolve → resident profile
  → tools         (roster §11: config sections → constructed, confined tools)
  → instructions  (Instructions.md + AGENTS.md, §3)
  → per session:  router.makeSession(workingDirectory:tools:instructions:
                    budget:compactionPrompt:)   ← the self-folding runtime session
  → RoutedACPAgent(name:router:configuration:commands:)  ← `name` is the
                    dotfolder name the frontend chose (§2.1)
```

**The conformance is a translation, not a construction.** Every ACP noun names
its peer in this stack, and anything with no peer is a capability switched off
honestly, never faked. Because ACP turns drive Router's sessions through the
prompt owner, everything the runtime owns — auto-compaction (proactive and
reactive), budgets, retry, chokepoint recording, confinement, the context meter
— works over ACP with zero wire-specific code. The lower layers never pretend to
be agents: `RoutedSession` stays Router's wire-free session surface,
`LanguageModelSession` stays Apple's conversation primitive. (Name note: the
wire package declares the protocol-role `Agent`; nothing else here is named
`Agent`, so `RoutedACPAgent: Agent` reads unambiguously.)

**We target ACP v2 only.** The stable v2 method set is `initialize`,
`auth/login`, `auth/logout`, `session/new`, `session/resume`, `session/list`,
`session/delete`, `session/close`, `session/prompt`, `session/cancel`,
`session/set_config_option`, `session/request_permission`, `session/update`.
`elicitation/*`, `mcp/*`, and `session/fork` are **unstable-schema-only** and
are planned but gated (§16, §11.5, §7.5). `session/list` / `resume` / `close` are
baseline in v2 — mandatory for any agent supporting sessions; "capability off"
is not available for them.

**One identity spans the whole stack.** Apple's `Transcript.ToolCall.id` =
Router's `SessionEvent.toolCall(id:)` = ACP's `toolCallId` = the MCP call handle
= `OperationEvent.correlationID` = `AgentSpawn.parentToolCallId`. One stable key
across five layers: it correlates the wire's tool updates, scopes elicitations,
keys SwiftUI `ForEach`, and makes a sub-agent's transcript reachable from
exactly the tool call the client watched execute.

Part I below covers the agent-side foundations (configuration, instructions,
transcripts). Part II covers the protocol surface, **organized in parallel with
the [ACP v2 spec](https://agentclientprotocol.com/protocol/v2/overview)** — one
section per spec page, in the spec's order. Tools live at **Tool Calls** (§11),
slash commands at **Slash Commands** (§14), session configuration at **Session
Config Options** (§15). Part III covers frontends, testing, and upstream
dependencies.

---

# Part I — Foundations

## 2. Configuration

### 2.1 The dotfolder name

**`<name>` is a construction parameter of the agent, supplied by the frontend.**
A bare word with no leading dot (`"coding"`, `"acme"`), not baked into any layer
below this one — Router, the wire, and the tool packages never see it. Two
frontends passing the same name share configuration and transcripts; two passing
different names are fully isolated on disk. The Mac app and the CLI deliberately
pass the *same* name (§19); a test or demo passes its own and touches nothing.

It reaches exactly three things:

| Consumer | Effect |
|---|---|
| `DotfolderStack(name:)` | the two config locations below |
| transcript root (§4) | `<cwd>/.<name>/transcripts/…` |
| `profile.name` default | falls back to `<name>` when unset |

Everything downstream receives *values* derived from it, never the name itself.

**Validation — this string becomes a path component.** Reject empty, any name
containing `/`, `\`, or a path separator, `.` and `..`, and any name starting
with `.` (the dot is added by the project layer, never supplied). Hard error at
construction, not a warning: a name that escapes its directory is a
config-file-writing primitive pointed at an arbitrary path.

### 2.2 The stack

`DotfolderStack` is **Extras'** type —
`init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)`,
with `userDirectory` and `environment` injectable so tests never touch the real
home. This package passes no `defaultsDirectory`. The layers, lowest precedence
first:

1. **Builtin defaults — in code, not on disk.** `AgentConfiguration`'s own
   property defaults *are* the default configuration: a curated coding-model
   profile that works out of the box on a 16 GB machine
   (`recording.level: full`, `transcripts.location: project`). There is no
   shipped `config.yaml`, nothing to materialize on first run, and no defaults
   directory. Layer 1 is code for every artifact, uniformly: config defaults,
   the compiled-in `Instructions.md` (§3.1), and builtin slash commands (Swift
   `.action` closures, §14.1). The rule that matters survives: **changing
   behavior must never require a rebuild** — every code-level default can be
   shadowed by a file, and `/config export` (§14.1) and
   `<cli> instructions --eject` (§3.1) write that file for you.
2. **User layer — `~/.config/<name>/`** (no leading dot). Resolved as
   `$XDG_CONFIG_HOME/<name>/` when that variable is set *and* absolute, else
   `~/.config/<name>/`. Machine-wide preferences.
3. **Project layer — `<project>/.<name>/`** (leading dot). Per-repo overrides.
   `<project>` is the **agent's session working directory** — ACP's
   `session/new(cwd)` — not the process's cwd. Load-bearing: one process serves
   many sessions in different repos, so this layer is resolved *per session*,
   and two concurrent sessions legitimately see different project config.

The dot placement follows each directory's own convention:

| | Path | Dot? | Why |
|---|---|---|---|
| User | `~/.config/<name>/` | **no** | `~/.config` is already hidden; XDG names its subdirectories bare |
| Project | `<project>/.<name>/` | **yes** | it sits at a repo root beside source |

### 2.3 Every file in the stack

| File | User layer | Project layer | Merge rule |
|---|---|---|---|
| `config.yaml` | ✅ | ✅ | key-level override |
| `Instructions.md` (§3.1) | ✅ | ✅ | **wholesale replace**, nearest wins — `DotfolderStack.content(_:)` *is* the rule |
| `AGENTS.md` (§3.2) | ✅ | ✅ | **additive**, user first then project |
| `_partials/` | ✅ | ✅ | nearest layer wins per partial name |
| `transcripts/` (§4) | opt-in | ✅ **default** | not layered — a location, not content |
| *(skills are their own stack — `DotfolderStack(name: "skills")`, §14.2)* | — | — | — |
| *(no per-tool config files — tools take **objects**, §2.5)* | — | — | `decisions.yaml` lands here once Shelltool `f9q2338` allows host-owned persistence |

`AGENTS.md` is the one **additive** row: it answers "in what order do they
compose," everything else answers "which layer wins."

### 2.4 Schema and loading

**The `AgentConfiguration` schema**: `profile` (standard/flash/embedding
slots), `tools` (built-in sections + `mcp`, §11.2), `recording`, `transcripts`,
`compaction`. There is **no `instructions` section** — the system prompt is a
markdown file (§3.1). Context size is derived from the model and deliberately
not configurable.

**Loading is Extras'.** `LayeredYAMLDocument` loads → renders through the
template engine (trusted for builtin defaults, untrusted for user/project
layers; `{{ env.TOKEN }}` is how secrets stay out of committed files) → merges
with the family's one rule → returns a value tree with per-key source tracking;
this package decodes it via `Codable`. Unknown top-level sections warn; unknown
keys inside a known section are errors. Router never sees any of it — sessions
receive values.

### 2.5 Tool packages take objects, not config files

**Configuration is read in exactly one place — here — and tool packages receive
constructed values.** No tool package reads a config file of its own, and no
tool package names a dotfolder convention. The mechanical test: **a tool package
that depends on Extras' `DotfolderStack` is doing configuration it should not
be.**

| Package | Takes | Status |
|---|---|---|
| `FoundationModelsFileTool` | `root`, `additionalRoots`, `readOnly`, `allowSymlinks` | ✅ complies |
| `FoundationModelsMCP` | server descriptions | ✅ complies |
| `FoundationModelsSkills` | layer **roots** (ordered, lowest first — §14.2) | ✅ by design: for skills the folders *are* the data (content discovery, not self-configuration) |
| `FoundationModelsShelltool` | today: config file URLs | ❌ until **`f9q2338`** lands: a host must be able to build a `ShellPolicy` from values and supply its own persistence. Its Extras dependency disappearing is the completion signal. Interim: inject URLs pointing at our dotfolder |

**`tools: shell:` in our `config.yaml` is the whole story** — decoded as
Shelltool's own option type (§11.1), from which this package constructs the
policy value:

```swift
ShellPolicy(rules: ShellPolicy.builtinRules + configured, decisions: store)
```

The builtin denials are compiled into Shelltool and concatenated here, so **no
config layer can remove them** — enforced by construction, not by a merge rule.

**One deliberate exception to §2.2's precedence, security-shaped: denials union
across layers.** A project-layer `deny` list must not replace a user's
machine-wide one — otherwise opening a repo could silently drop "never run
`rm -rf`". Denials are a floor: builtin, user, and project denials all apply.
`allow` and `ask` follow ordinary override. Implemented in our codec, stated
here.

**`decisions.yaml` is state, not configuration.** Remembered `allow_always` /
`reject_always` answers are written by the agent, not authored by the user.
Shelltool defines the decision vocabulary and matching; **this package decides
where, and whether, it persists**. `ShellDecisionStore.Scope` defaults to
`.session` (in memory, written nowhere) with `.project` / `.user` chosen
deliberately — preserve that default: the project dotfolder is **committed**
(§4), and "always allow" must not silently produce a tracked file change in a
shared repo.

## 3. Instructions

### 3.1 The system prompt — `Instructions.md`

**One markdown file, resolved through the ordinary layering — nearest wins,
wholesale:**

| Layer | Location | Notes |
|---|---|---|
| 1 | **compiled in** | the guaranteed floor; never edited, only shadowed |
| 2 | `~/.config/<name>/Instructions.md` | machine-wide replacement |
| 3 | `<project>/.<name>/Instructions.md` | per-repo replacement |

The compiled-in floor exists because the prompt is the one artifact where
*nothing* is not a valid value: absent config means defaults, an absent
`skills/` means no commands, but an absent system prompt means a silently
lobotomized agent.

**Replacement is wholesale; addition has its own lane.** A layer-3
`Instructions.md` replaces the base entirely — merging prose is meaningless.
Additive instructions belong in `AGENTS.md` (§3.2). The two lanes:
**`Instructions.md` replaces, `AGENTS.md` adds.**

**Discoverability obligations** (the cost of a compiled-in floor): the builtin
text is reproduced verbatim in DocC/README; the CLI can print the assembled
prompt and **eject the builtin** to a layer-2/3 path
(`<cli> instructions --eject`) — the counterpart of `/config export`. Consider
a `/instructions export home|project` builtin for symmetry from inside a
session.

**Resolution and rendering are Extras', not a bespoke lookup:**

```swift
// Stacking: content(_:) returns the NEAREST layer's file, whole.
let source = stack.content("Instructions.md")

// Trust is derived from where it came from, never configured:
let text  = source ?? Self.builtinInstructions
let trust: TemplateEngine.Trust = (source == nil) ? .trusted : .untrusted

// The engine takes the stack, so {% include %} resolves _partials/ through the
// same layering.
let rendered = try engine.render(text, context: context, trust: trust)
```

- **No layer-walking of our own** — `content(_:)` *is* the resolution rule
  (`nearest(_:)` / `locate(_:)` exist for diagnostics).
- **Trust is derived**: `nil` means the floor renders trusted; anything from
  disk renders untrusted. Layers 2 and 3 are both untrusted, so there is no
  third case.
- **Partials stack, and that is the useful part**: a project can override one
  partial without replacing the whole prompt — recovering the granularity
  wholesale replacement costs, without inventing a merge rule for prose.

The untrusted render is validated, side-effect-free, with no filesystem or exec
reach, metered on include-depth, loop-iteration, and output-size budgets. A
hostile `Instructions.md` in a cloned repo is bounded like any other untrusted
document.

### 3.2 Agent-instructions files — `AGENTS.md` via Extras' `AgentsMd`

These are context files, not memory — per [agents.md](https://agents.md/), "a
README for agents." Nothing here remembers anything across sessions. The
discovery walk is Extras' `AgentsMd` (shared with FoundationModelsAgents for
sub-agent instructions); this layer consumes it. Resolution is **per session,
relative to its working directory** — never per process.

At session creation, two sources are assembled:

1. **User-level** — `~/.config/<name>/AGENTS.md` via
   `DotfolderStack.content("AGENTS.md")` (our extension; the spec has no
   home-directory concept), prepended most-general-first.
2. **Project-level** — `AgentsMd.documents(from: cwd)`: the walk from the
   repository root down to the session's cwd, reading at each directory the
   first of `AGENTS.md`, `AGENT.md` (the spec's migration alias), `CLAUDE.md`
   (ecosystem-compatibility alias) — one file per directory, outermost-first so
   nearest-to-cwd lands last (the spec's "closest one takes precedence").

**Assembly order:** base prompt (`Instructions.md`, §3.1) → user-level
`AGENTS.md` → project-level documents (root → cwd). The last word belongs to
the nearest `AGENTS.md`. Each file is delimited by a header naming its absolute
path, so the model and anyone reading the session's `instructions` can
attribute every line. Missing files are simply absent; a present-but-unreadable
file is a logged warning, not a hard error — this is content, not
configuration. Each document renders through the template engine (untrusted)
before assembly.

The assembled text is read once at session creation, folded into the
`instructions` value handed to `makeSession`, and pinned for the session's
lifetime — a new session picks up edits. Instructions are never folded by
compaction (Router's invariant), so this context survives every fold by
construction. Router never knows any of this happened.

## 4. Transcripts

### 4.1 Location: project-local, keyed by ACP session

**`<cwd>/.<name>/transcripts/<sessionId>/`.** A transcript is project context,
not a personal activity log: what the agent did to a repo belongs with the
repo — it travels when the repo travels, and it is there for a teammate who
clones it.

```
<cwd>/.<name>/                       # the same project dotfolder as config.yaml
    config.yaml                      # committable — team settings
    transcripts/
        .gitattributes               # linguist-generated + merge=union (committed)
        sessions.jsonl               # this project's session index
        01K3G.../                    # ACP sessionId
            transcript.jsonl
```

- **No project slugs.** The directory is the identity. (The
  `-Users-…` slug scheme survives only for `transcripts.location: home`.)
- **The organizing key is the ACP session, not the Router run.** A routerId is
  provenance, not structure — recorded as metadata inside the session
  directory, never a path segment. Router's
  `recordingDirectory(forSessionId:recordingRoot:)` (landed as `ke41yth`)
  yields the flat `<root>/<sessionId>/` layout;
  `makeSession(recordingRoot:)` receives `<cwd>/.<name>/transcripts/`.
- **`transcripts.location` overrides**: `project` (default), `home` (shared
  root + slugs), or an absolute path.

### 4.2 One ACP session is one root Router session — and nothing else is

**The ACP `sessionId` *is* the root Router session's ULID** — the same
identifier serialized, not a mapping. (ACP's `SessionId` is an opaque string; a
mapping table can drift, and the first symptom would be a `session/resume` that
restores the wrong conversation.)

Router's two kinds of descendant, kept precise:

| | What it is | How it links | Directory |
|---|---|---|---|
| **fork** — `fork(workingDirectory:)` | a branch of the same conversation | `parentId` | nests: `<rootId>/<forkId>/` |
| **agent spawn** — `AgentSpawn(parentSessionId:parentToolCallId:)` | a sub-agent launched by a tool call | `parentToolCallId` — the spawning tool call | its own directory; linkage is the id, not nesting |

**Neither is an ACP session.** Forks and sub-agents never receive an ACP
`sessionId`, never appear in `session/list`, and never accept `session/prompt`.
From the client's side a sub-agent is something the agent *did* — a tool call
with a kind and content — not a second conversation.
`AgentSpawn.parentToolCallId` is the same id as ACP's `toolCallId` (§1's
identity chain), so a sub-agent's transcript is reachable from exactly the tool
call the client watched execute.

Two rules fall out:

- **`session/list` filters to roots**: listable iff `parentId == nil` and
  `agentSpawn == nil` — both already on the sidecar, so this costs a predicate.
- **`session/close` closes the tree**: a running fork or in-flight sub-agent is
  the session's ongoing work (§10.1).

**Where a sub-agent's transcript lands:** under whatever project root its own
cwd implies — a sub-agent in another repo belongs to *that* repo's transcripts
— linked by `parentToolCallId` as a sibling. Forks, which share the parent's
conversation, keep nesting under it.

### 4.3 Transcripts are committed — the transcript is the source

**Checked in, not ignored.** The transcript is the new source and the code is
its output: the prompts, decisions, and corrections that produced a change are
the durable artifact; the diff is what fell out of them. Nothing under
`.<name>/` is ignored by default. Consequences, each a design obligation:

- **Per-session directories make this mergeable.** Two developers produce two
  `sessionId` directories — no conflict by construction. The one shared file,
  `sessions.jsonl`, is **append-only, one self-contained record per line**,
  with `merge=union` in `.gitattributes`; treat it as a derivable cache,
  rebuildable by scanning session directories, so a mangled index is never
  load-bearing.
- **Marked as generated.** `.gitattributes` sets `linguist-generated=true` on
  `transcripts/**` — out of language statistics, collapsed by default in PR
  review.
- **Repo size is a real cost with no clean mitigation.** At
  `RecordingLevel.full` a transcript embeds the full contents of every file fed
  to a tool. `recording.level` is the control, and it is per-project: a repo
  can choose `metadata` and keep the shape of its history without the payload.
  Say plainly in the docs: full transcripts are the default because they are
  the valuable thing, and they are not free.

### 4.4 No redaction — deliberately

**Transcripts are recorded verbatim. There is no redaction pass, and Router's
`redact:` is not configured.** Operating assumption, stated so it can be
checked: this is a development tool, in development trees, against development
credentials; the control for a repo whose history should not be public is the
repo's own visibility. Two affirmative reasons:

- **Redaction corrupts the source.** A pattern matcher that rewrites a
  misidentified line produces a record that no longer says what happened.
- **Partial redaction invites misplaced confidence.** No pattern set catches
  every secret; "redacted" transcripts get treated as safe to publish.
  Verbatim-and-private is an honest posture.

**`recording.level` remains the control for repos that want less** —
`metadata` records shape without content, `off` records nothing — committed in
the project layer so it applies to everyone working there. If the assumption
ever stops holding (public repo, regulated codebase, production credentials),
the answer is `recording.level`, not redaction; a line in the docs makes the
premise visible.

### 4.5 Cross-project browsing — the project registry

The app's cross-project session browser needs "what was I doing in repo X last
week?" **Keep a project registry in the user layer** —
`~/.config/<name>/projects.jsonl`, appended when a session is created in a cwd
not seen before: absolute path, first seen, last seen. **Paths only, never
content.** A cache, not a record: regenerable, safe to delete; stale entries
are skipped on read.

### 4.6 `TranscriptStore`

The read side both frontends and `session/list` need:
`sessions(inProject:)` (a plain directory read), a paged variant for cursor
pagination (§9), `allProjects()` via the registry, and
`transcript(for sessionID:) -> [Transcript.Entry]` via Router's
`TranscriptTree` reconstruction.

The ownership boundary: **`TranscriptStore` never records and never restores.**
It owns the root location policy, the project registry, and lightweight browse
summaries. Everything that gives a `transcript.jsonl` meaning — writing events,
reconstructing entries, applying compaction checkpoints, rebuilding a live
session (`RoutedLLM.restoreSessionTree`) — is Router's, and this package calls
Router to do it.

Persisted per session, because `session/list` (§9) needs them and they are not
derivable after the fact: a generated **title** (from the first user prompt,
truncated single-line; a model-generated title is a follow-up), **`updatedAt`**
(maintained in the record, not stat-ed), and the session's **complete ordered
`additionalDirectories` list** — an ordered list, not a set, *replaced* on
every `session/resume`.

---

# Part II — The protocol surface

*One section per ACP v2 spec page, in the spec's order. Each section states the
peer for that page's nouns; anything with no peer is switched off honestly.*

## 5. Initialization

**`info` is required.** `InitializeResponse` requires `protocolVersion` and
`info`; `Implementation` requires `name` and `version` (`title` optional).
Report `name` as the programmatic identifier — the package/product name, *not*
the dotfolder `<name>`, which is a user's private choice with no business on
the wire — `title` as the display name, `version` as the build version. Clients
surface these.

**Version negotiation is behavior, not a number** (`ProtocolVersion` is a
`uint16`). The client sends the latest
version it supports; if we support it we MUST echo the same integer; otherwise
we MUST respond with the latest we support, and the *client* decides to
disconnect. Concretely, v2-only means: **a client that sends `1` gets `2` back
in a normal successful response — not an error.** Log it, answer honestly, let
them hang up.

**What we advertise** (`capabilities`, `info` — v2's names; not
`agentCapabilities`/`agentInfo`):

- `capabilities.session` baseline `{}` at minimum, with:
  - `prompt` — which content types the roster can actually consume (§12).
  - `mcp: {stdio: {}, http: {}}` (§11.5).
  - `delete: {}` — advertised; a real delete (§10.2).
  - `additionalDirectories: {}` — advertised; confinement is multi-root (§7.2).
- **Capability markers are objects, not booleans, all the way down** — `{}`
  means supported; omitted or `null` means not. No `true` anywhere.
  (`PromptCapabilities` members are `PromptImageCapabilities` /
  `PromptAudioCapabilities` / `PromptEmbeddedContextCapabilities`; `mcp`'s are
  `McpStdioCapabilities` / `McpHttpCapabilities`.)
- **`capabilities.auth` and `authMethods` are both omitted** (§6).

**Reading the client's capabilities: absent means unsupported** — the spec's
own MUST. Stable v2's `ClientCapabilities` carries only `_meta`, so today there
is nothing to read; the rule still governs the `_meta`-negotiated elicitation
gate (§16), which must default to unsupported when the key is missing.

**Be forgiving about malformed capabilities.** The schema marks `capabilities`
`x-deserialize-default-on-error` with `default: {}` — a capabilities object we
cannot parse degrades to "supports nothing" rather than failing `initialize`.

**Ordering is enforced.** Clients MUST initialize before creating a session; a
`session/*` call arriving first is answered as a JSON-RPC invalid request
rather than served — serving it would mean acting on capabilities never
negotiated.

## 6. Authentication

**None — a local on-device agent has no authentication surface.** Omit
`authMethods` (the spec: agents without authentication needs simply omit it),
which removes the obligation to implement `auth/login` and `auth/logout`;
clients MUST NOT call either. The `auth_required` error (-32000) is never
raised. A buggy client that calls `auth/login` anyway gets **`-32601`** ("the
method does not exist **or is not available**" — the right code because the
method exists in the protocol but not on this agent). Auth method descriptors
key on `methodId`, not `id`.

**"No ACP auth" is not "no credentials."** ACP authenticates the agent to the
client; MCP servers are a separate axis and do carry credentials — an `http`
server's `headers` (§11.5), supplied by our config or by the client. The rule
that keeps those two facts compatible with committed transcripts (§4.3):
**never persist client-supplied MCP server configurations** (§7.3).

## 7. Session Setup (`session/new`, `session/resume`)

### 7.1 What a session is

One ACP session = one root Router session, same ULID (§4.2). `session/new(cwd)`
⇒ per-cwd config layer (§2.2) + tool roster (§11) + assembled instructions (§3)
→ `router.makeSession(...)`. `cwd` MUST be absolute and MUST be part of the
session's effective root set — load-bearing, since `cwd` is literally where
transcripts are written (§4.1).

**Multiple concurrent ACP sessions are supported from the start.** Sessions are
keyed by `sessionId`, each with its own cwd-derived config layer, instructions,
confinement, and transcript directory; turns serialize at the model's
`serialGate`; recording stays per-session at Router's chokepoint.
**Per-project profiles are implementable**: Router's pooled, reference-counted
residency (`kh01tv2`, landed — covered by `PooledResidencyTests`) gives one
memory-budget authority, shares a model two profiles both name, fails cleanly
when a union exceeds the budget, and keeps gate waits `Task`-cancellation-aware
so a queued session's `session/cancel` never outwaits another session's turn.

**One prompt per session at a time**: `idle` means "ready for a new prompt," so
a `session/prompt` arriving while not idle is a client error, not a queue.
Queueing stays composer-owned; Router's own prompt queue is deliberately not
exposed over ACP.

### 7.2 `additionalDirectories` — multi-root confinement

Advertised and honored; **not a passthrough field** — accepting it while
confining to cwd alone would reject every tool call outside the primary root,
worse than not advertising.

- `session/new` and `session/resume` carry `additionalDirectories:
  [AbsolutePath]`. Every path MUST be absolute; the array is
  `x-deserialize-skip-invalid-items`, so a malformed entry is skipped and
  logged, never a rejected session. **The list is ordered**, and the order is
  persisted per session (§4.6).
- **The roots expand confinement only, without changing `cwd`.** `cwd` remains
  the base for relative paths, and everything else keyed off it stays
  **singular**: the config layer (§2.2), the AGENTS.md walk (§3.2), and the
  transcript directory (§4.1). A vendored dependency you can read is not a
  project whose `AGENTS.md` governs you, and a second root must never fork the
  transcript location. `PathGuard` gets the root set; `ShellPolicy` accepts the
  roots as valid working directories.
- **On resume the list is authoritative and replaceable, not sticky.** A
  non-empty list is the complete resulting root set; omitted or empty means
  **no** additional roots — never inherit the session's former roots.
  Rebuilding confinement from exactly what the request carries is what keeps a
  boundary the client just narrowed from silently re-widening.

Upstream: FileTool `939nnzx` (multi-root `PathGuard`) is the one blocking
dependency, in progress. Shelltool needs nothing — it is not root-confined
(§11.4).

### 7.3 `mcpServers` — the client's servers

`session/new` and `session/resume` both carry `mcpServers: [McpServer]`.
Client-supplied servers are session-scoped, connected **in addition to**
config-derived ones (arriving after them; ACP's `name` is our
`ServerIdentity`). **Open decision, recorded as such**: whether a
client-supplied server may *override* a config-derived one on a name
collision, or the collision is refused — state the rule before implementing.
Connection must complete **before** the tool array
reaches `makeSession(tools:)` — Router's tool-instancing pipeline is
synchronous — which means during `session/new`/`session/resume` handling.

**Never persist the client-supplied list.** `session/resume` carries
`mcpServers` itself, so the client is the source of truth on every reconnect —
no storage, no staleness, no reconciliation. Necessary as well as simpler: an
`http` server's `headers` carry bearer tokens, and §4.3 commits session
metadata to a shared repo. Config-derived servers are the user's own committed
file and their own decision; `{{ env.TOKEN }}` templating (§2.4) keeps the
secret out of it. This is a constraint on our `sessions.jsonl`; Router's
`session.json` sidecar is already clean.

Shapes worth pinning: `McpServerStdio` requires only `name` + `command`,
`McpServerHttp` only `name` + `url` — `args`, `env`, `headers` are genuinely
optional, not required-but-empty. `env` and `headers` are **arrays of
`{name, value}`, not maps**; duplicate names are representable — last-wins.

### 7.4 Resume and replay

- **The client's `cwd` MUST match the original** — validate against the cwd
  Router recorded at creation and error on mismatch rather than silently
  re-rooting confinement. (Confirmed from the other direction:
  `SessionInfoUpdate` has no `cwd` field, so a session's cwd cannot
  legitimately change — §9.)
- Restore reassembles this package's side (config layer, instructions,
  confinement) from the recorded cwd; Router restores the session itself
  (Router board `6j4bven`).
- `replayFrom: {"type": "start"}` replays history before the response returns;
  omitted/`null` skips replay. **Replay emits whole-message upserts**
  (`user_message` / `agent_message` / `agent_thought`) reusing the original
  `messageId`s — **not** the `*_chunk` variants a live turn produces. Same ids
  are what let a client that already saw some messages converge rather than
  duplicate.
- **`ReplayFrom` is an inclusive cursor**, of which `start` is only the first
  variant. Write the replay path parameterized by cursor, not hardcoded to
  replay-everything — resuming from a message id is the obvious next variant.
- **Replay comes from Router's full recorded history** (the conversation the
  user actually had); **the live session is constructed from the newest
  compaction checkpoint** (the model's working transcript). Two different
  transcripts, deliberately.
- Resuming a deleted session fails naturally — the transcript is gone (§10.2).

**`configOptions` rides both responses** — `NewSessionResponse` and
`ResumeSessionResponse` each carry it, and that is the list's primary
announcement (§15).

### 7.5 `session/fork`

**Unstable-schema-only — but the peer exists**: Router already forks sessions
(§4.2). If the method graduates to stable, this is a cheap win rather than new
machinery. Do not build it against the unstable schema.

## 8. Prompt Lifecycle

### 8.1 The turn: acknowledge, then notify

`session/prompt` returns `{}` **immediately** on acceptance; the turn arrives
as notifications. **Order matters**: respond `{}` *first*, then `user_message`,
then `state_update: running`, then the turn's output, then `idle` +
`stopReason`. The wire package supplies the primitive —
`AgentSideConnection.afterRespondingToCurrentRequest(_:)` defers work until the
`{}` has gone out; use it rather than a detached task that races the response.

The handler dispatches slash commands (§14.3) before any of this. **Echoing the
prompt is a MUST** — "the Agent MUST report where the user message was inserted
in session history" — and that update is the source of truth for the
agent-owned `messageId`; a `user_message_chunk` stream satisfies it equally.

### 8.2 The state machine

`state_update` carries `running` / `idle` / `requires_action`, and it needs a
named owner in the conformance:

- `running` on turn start.
- **`requires_action` whenever we block on the human** — around
  `session/request_permission` and around every elicitation round-trip (§16) —
  paired with Router's `awaitingUser { }` so the per-model generation gate is
  released at the same moment the protocol says "blocked on user." Back to
  `running` on the answer. (`requires_action` is "foreground work blocked on
  user action" — permission is merely the common case.) A turn sitting in
  `running` while silently waiting on a person renders as a hung agent; Router
  otherwise holds the gate across the whole turn, blocking every other session
  and fork on that model.
- `idle` with a `stopReason` at turn end. Background work may continue while
  `idle`; its notifications do not change the state.

**`StopReason` mapping**: completed → `end_turn`, guardrail refusal →
`refusal`, cancel → `cancelled`, budget exhaustion → `max_tokens`, tool-loop
cap → `max_turn_requests`; `_`-extensible. **Catch the cancellation exception
and map it** — a Swift `CancellationError` escaping as a JSON-RPC error or as
`refusal` is the failure the spec names.

### 8.3 The upsert algebra

The foundation the compaction and replay decisions rest on. Messages are keyed
by the agent-generated **`messageId`** — v2: "the Agent owns session history,
so it is the single source of message identity," which is our "the
FoundationModels `Transcript` is the record" invariant as the protocol's own
position.

| Update | Effect on the message with that `messageId` |
|---|---|
| whole-message, `content` omitted | content unchanged (other fields may update) |
| whole-message, `content: null` or `[]` | cleared |
| whole-message, `content: [X]` | **replaces everything accumulated**, chunks included |
| `*_chunk` | appends |
| any update with a new `messageId` | a new message begins |

The third row is load-bearing: it is why compaction can correct a client's view
by re-sending affected messages, and why replay-as-upserts converges a client
that already saw the chunk stream. `ContentChunk` requires `messageId` **and**
`content`; whole-message forms require only `messageId`.

### 8.4 The `session/update` stream — Router's events on the wire

| Router `SessionEvent` | ACP `SessionUpdate` (v2 discriminator) |
|---|---|
| `textDelta` | `agent_message_chunk` (with the agent-generated `messageId`) |
| `reasoningDelta` | `agent_thought_chunk` |
| `toolCall(id:name:argumentsJSON:)` | `tool_call_update` — v2 has no `tool_call` create variant; the first update carrying an unseen `toolCallId` *is* the creation, and SHOULD carry `title` |
| `toolStatus(id:status:summary:)` | `tool_call_update` (`running` → `in_progress`) |
| `compaction(CompactionResult)` | `agent_message` / `user_message` upserts — §8.5 |
| `turnEnded(TokenUsage)` | `usage_update` |
| turn start / turn end | `state_update` — `running`, then `idle(stopReason)` |

v2 discriminators are **`snake_case`** (`agent_message_chunk`,
`tool_call_update`, `in_progress`) while JSON *properties* are `camelCase` — an
easy place to get the wire wrong.

- **`usage_update` is the context meter, native**: `{used, size, cost?}` maps
  straight onto Router's token metering and resolved context.
- **`session_info_update`** carries title/metadata changes mid-session — e.g.
  the moment the first prompt yields a generated title (§4.6).
- ACP's `ToolCallStatus` is `pending` / `in_progress` / `completed` / `failed`
  / `cancelled` — `pending` (a queued call) and `cancelled` are additions over
  Router's vocabulary; a detached MCP call is `in_progress` across turns. The
  enum is extensible:
  MCP's `lost` outcome rides as **`_lost`** (§18), with "we do not know whether
  this ran" in accompanying text for clients that ignore custom values.

### 8.5 Compaction on the wire

Compaction rewrites history; a client that only accumulates goes silently
stale. **On compaction, emit `agent_message` / `user_message` upserts for the
affected `messageId`s** — `content: null` for messages the fold removed,
replaced `content` for any it rewrote — plus one `agent_message` for the
summary the fold produced. History rewriting is expressible in the protocol's
own vocabulary; no `_meta` extension, no client round-trip. The fallback for a
client that missed the upserts or joined late: `session/resume` +
`replayFrom: start` (§7.4).

**Upstream (open):** this requires knowing which `messageId`s a fold touched —
Router's `CompactionResult` must carry message-level identity, not just a
checkpoint.

### 8.6 Cancellation (`session/cancel`)

A notification, with a defined confirmation: respond to every pending
`session/request_permission` with the **cancelled** outcome, stop work, then
emit `state_update` `idle` with `stopReason: "cancelled"`. Agents MAY send
updates after receiving `session/cancel` but MUST do so *before* the idle
update — `idle` + `cancelled` is strictly the terminator. The client's half
(preemptively marking unfinished tool calls cancelled, answering pending
permissions) is its job; we still emit accurate terminal tool statuses, but do
not block the `idle` on having done so.

**The chain has a known gap**: Router's cancellation is queue-side — a turn
already handed to the model runs to completion. Chaining `session/cancel` to an
in-flight MCP call needs Router's in-flight cancellation first (open upstream);
even then MCP's `notifications/cancelled` is advisory, so the honest UI outcome
is "we stopped listening," not "it stopped."

## 9. Session List (`session/list`)

Backed by `TranscriptStore.sessions(inProject:)` (§4.6) — with project-local
storage, the common `cwd`-filtered query is a single directory read; the
unfiltered cross-project list goes through `projects.jsonl` (§4.5). A filter
naming a directory we have never seen returns an **empty array, not an error**.
Baseline — not capability-gated.

**`SessionInfo`**: `sessionId` and `cwd` (absolute) are required; `title`,
`updatedAt`, `additionalDirectories` are optional in the schema. We generate
and persist a title anyway (product decision, not conformance — §4.6), maintain
`updatedAt` (RFC 3339), and report `additionalDirectories` as the complete
ordered list from the most recent activation.

**Immutability**: `SessionInfoUpdate` carries only `title` and `updatedAt`
(each nullable to clear). There is no mechanism for `cwd` or the root list to
change — which confirms the resume `cwd` check (§7.4) — and no way to push a
root-list change; a connected client learns of a changed root set only on its
next `session/list`. Protocol gap; do not synthesize an update for it.

**Ordering and pagination are ours to define, and they must agree.** Sort
**`updatedAt` descending, `sessionId` tiebreak**. `session/list` is
cursor-paginated — request params are `cwd` (filter) and `cursor`; the
response carries `nextCursor` — with opaque tokens (clients MUST NOT parse or
persist them), a bounded page size, and an error on an invalid cursor. **The cursor encodes the sort
key, not an offset**, so pagination survives concurrent writes without
duplicates or skips.

**What is listable** (the spec leaves it open):

| Session state | Listed? | Why |
|---|---|---|
| active | yes | — |
| closed | **yes** | closing frees resources but retains the transcript; resuming it is the point |
| deleted | no | delete removes it from history by definition |
| created, zero turns | **no** | nothing to resume; noise in every picker |

The zero-turn rule is free: a session directory is written when there is
something to record, so "has a persisted transcript" *is* the listability test.
Roots only: `parentId == nil && agentSpawn == nil` (§4.2) — forks and
sub-agents never surface as conversations.

## 10. Session Management (`session/close`, `session/delete`)

### 10.1 `session/close`

A **MUST**: cancel the session's ongoing work "as if `session/cancel` had been
called," then free resources. That inherits cancellation's full semantics
(§8.6): pending permission requests get the cancelled outcome, and a close
during an active turn **emits `state_update` `idle` with
`stopReason: "cancelled"` before the close response** — a client with a spinner
up otherwise never learns the turn ended. Then free: in-flight MCP calls,
detached work, spawned stdio server processes (§11.5), **and the session's
descendants** — a running fork or in-flight sub-agent is this session's ongoing
work, and leaving it burning a model gate after close is the failure this MUST
exists to prevent. Recording closed; transcript **retained** on disk.

### 10.2 `session/delete`

**Capability-gated; advertised; a real delete, not a tombstone.** Remove
`<cwd>/.<name>/transcripts/<sessionId>/` and its `sessions.jsonl` entry. The
spec leaves soft-vs-hard to us; a user asking to delete means gone. **Version
control is what makes that safe**: `git rm` is an ordinary operation precisely
because history preserves what it removes — retention in git history is the
recovery path, not a reason to keep the file in the working tree.

- Deleting an active session: close it first (§10.1 semantics, descendants
  included), then delete.
- Resuming a deleted session fails — the transcript is genuinely gone; the
  absence does the work.
- Already-deleted and never-existent both succeed silently: nothing to remove
  is not an error (a directory removal gives this naturally).
- **Honesty**: the delete removes the working tree and index copy; anything
  already committed remains in git history. Neither the ACP response nor the
  docs may claim the content is unrecoverable.

## 11. Tool Calls

*The tools' home. v2 removed `fs/read_text_file`, `fs/write_text_file`, and all
five `terminal/*` client methods, and redirects agents to their own file
access, their own execution, and MCP — so the built-in roster below is the
**entire surface** by which this agent reaches the user's world, and in-process
tools are the sanctioned design, not an accepted risk. What remains ours is the
confinement story: `PathGuard` bounds `files`, the stacked `ShellPolicy` bounds
`shell`, and `session/request_permission` is how the user is asked before
either exceeds it.*

### 11.1 The catalog

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the single place
tools are registered — one reserved config section per linked package; adding a
tool is a dependency plus one catalog line:

```swift
/// The tool catalog.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW TOOLS HERE — and only here.
///   1. Put the implementation in Tools/<Name>/.
///   2. Append its constructor to `builtin(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in this package needs to change.
/// ══════════════════════════════════════════════════════════════════
public enum ToolCatalog {
    public static func builtin(context: ToolContext) -> [any FoundationModels.Tool]
}
```

`ToolContext` carries what every constructor needs — the session working
directory, the session's additional roots, the decoded config section.
Frontends may append their own tools; the merged array is what
`makeSession(tools:)` receives. Catalog entries are also where slash-command
providers register (§14.2): an entry may pair its tool with a
`SlashCommandProviding` conformer, fed into the session's command registry.
The direction rule is absolute — tool packages conform to the leaf's protocol;
nothing outside this package ever names its types.

### 11.2 The enable/disable rule

**Every built-in is on unless the config turns it off — absence enables.** A
user with no config file gets an agent with all tools, each with its own
defaults. One rule, five shapes:

| Config | Meaning |
|---|---|
| no `tools:` section | every built-in on, with defaults |
| `tools:` present, tool not mentioned | that tool on, with defaults |
| `shell: {}` / `shell:` (null) / `shell: true` | on, with defaults — explicit but redundant |
| `shell: {policy: strict}` | on, body decoded as **that package's own option type** |
| **`shell: false`** | **off** — not constructed, never reaches the model |

`false` sits deliberately *outside* the body: the body is the tool package's
own option type, unknown keys inside it are errors (§2.4), and an `enabled:`
key would force every package to carry a flag only this layer cares about. The
codec checks for a scalar `false` first, then decodes the mapping.

- Disabling is per-tool, one at a time. No `tools: false` mass-switch, no
  `only:` allowlist — a config that silently removed the whole roster would be
  too easy to write by accident.
- Layering is §2's ordinary key-level override: the nearest layer that mentions
  the tool wins, so a user layer may disable and a project layer re-enable.
- **A new built-in arrives enabled** for every existing user on upgrade. That
  is the intended batteries-included behavior — but it makes adding a roster
  entry a user-visible capability change; release it like one.

**`mcp:` is the one entry whose body is a list** (servers, not options):

- **omitted** — enabled with no configured servers; the ACP client's
  per-session `mcpServers` (§7.3) still connect. The right default: an editor
  supplying its own servers works against a stock config.
- **`mcp: [ … ]`** — those servers, plus any the client supplies.
- **`mcp: false`** — MCP off entirely, **including refusing client-supplied
  servers**: a deliberate security posture ("this agent talks to nothing I did
  not link"), distinguishable from `mcp: []`. Log the refusal — a client whose
  servers vanish without explanation is the worst version of this.

### 11.3 The roster

**Built in, day one — declared dependencies, in the default roster:**

| Tool | Source package | Blocked on | Config section |
|---|---|---|---|
| `files` | `FoundationModelsFileTool` (**built**) | nothing | `files:` |
| `shell` | `FoundationModelsShelltool` (**built**) | nothing | `shell:` |
| MCP servers | `FoundationModelsMCP` (**built**) — `MCPToolProvider` | nothing; the ACP tunnel is unstable-gated (§11.5) | `mcp:` (plus ACP's per-session `mcpServers`) |
| skills → `/id` commands | `FoundationModelsSkills` (**plan-only**) — the command-provider half | Skills M1–M3 + M5; Extras only (shipped) | `skills:` |
| skills → `search`/`list`/`use` tool | `FoundationModelsSkills` (**plan-only**) — the model-facing half | Skills M4 → `FoundationModelsOperations` 2/4/5 **and** `FoundationModelsMetadataRegistry` M1–M4, neither built | `skills:` |

**Follow-ups — one catalog line each as their packages ship:**

| Tool | Source | Blocked on | Config section |
|---|---|---|---|
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | thin `Tool` shim over `CodeContext` | nothing; first follow-up | `codeContext:` |
| `runCode` | `MultiTool` (JS composition over the catalog) | nothing | `multitool:` |
| sub-agents | FoundationModelsAgents | that package (plan-only) | `agents:` |

**Skills is both a tool and a command provider, and the halves answer different
questions**: the tool is *discovery* ("what can I do here?", for the model);
the `/id` commands are *explicit dispatch* ("do this specific thing", for the
user). Day one ships **explicit dispatch without discovery** — the command half
depends only on shipped Extras; the tool half's dependency chain does not exist
yet. Until it lands, skills are invisible to the model entirely — a real
difference from `files`/`shell`, decided deliberately rather than inherited
from a dependency chain. (Phasing details and the two integration gaps: §14.2.)

### 11.4 Confinement

- **`files`** — confined by `PathGuard` to a **root set**: the session's cwd
  plus its `additionalDirectories` (§7.2). `cwd` stays the privileged member
  (the relative-path base), but a path resolving inside any root validates.
- **`shell`** — gated by the stacked `ShellPolicy` (§2.5): a three-outcome
  policy (`.allow` / `.ask(reason)` / `.deny(message)`) with a
  `ShellDecisionStore` behind `remember(...)`, which is what
  `session/request_permission`'s `allow_always` / `reject_always` bind to
  (§11.7). **The shell is not root-confined, and `additionalDirectories` does
  not change that**: `ShellContext` carries no workspace root;
  `check(workingDirectory:)` validates only `..` traversal and existence.
  Confinement for `shell` is command-and-environment pattern rules, not a
  filesystem boundary — a shell command's blast radius is bounded by policy,
  and widening the workspace does not widen it. (Whether `shell` should
  *additionally* be root-confined is a separate open question.)
- **`mcp`** — dynamic: the tools it yields depend on what the servers
  advertise, and connection completes before the array reaches
  `makeSession(tools:)` (§7.3).

### 11.5 MCP wiring: two sources, two transports (+ one unstable), two sinks

**Sources**: local `mcp:` config and the ACP client's per-session `mcpServers`
— composed per §7.3 (client servers session-scoped, after config-derived ones,
never persisted).

**Transports** (advertised as `McpCapabilities` at `initialize` —
`capabilities.session.mcp`; nothing does that today):

- **stdio** → `StdioServerProcess`; `McpServerStdio`'s fields map
  field-for-field. `capabilities.session.mcp.stdio`.
- **http** → `HTTPClientTransport`, ACP's `headers` supplying auth
  (authorization stays the host's job per `FoundationModelsMCP`'s decision).
  `capabilities.session.mcp.http`.
- v2 removed `sse` outright — no `McpServerSse` exists, no third stable
  transport.

**The ACP tunnel is unstable-schema-only — plan it, gate it, don't promise
it.** `mcp/connect` + `mcp/message` + `mcp/disconnect` exist only in
`acp-v2.meta.unstable.json`, with no stable capability to request a tunnel. The
design when it lands: the **client** hosts the server and the agent tunnels MCP
JSON-RPC over ACP; **`ACPTunnelTransport` belongs in this package** — it is an
`MCP.Transport` conformance that needs ACP types, and `FoundationModelsMCP`
must never depend on `FoundationModelsACP`. It plugs into that package's
transport factory; the client owns the processes, so `StdioServerProcess` is
bypassed. Doubly blocked: on the wire package generating the `mcp/*` payload
types, and on the methods graduating to stable. Ship stdio + http first.

**Process lifecycle is FoundationModelsMCP's job, not ours** — spawning and
owning stdio subprocesses, reconnects, pooling across sessions are upstream
asks on that package; this package passes entries to `MCPToolProvider` and
receives `[any Tool]`.

**Two sinks for one tool call** — a long-running MCP call reports to both
audiences:

- **model-visible** — `OperationEvent` → Router's `SessionOutbox` → transcript.
- **user-visible** — `tool_call_update`: `toolCallId`, `status`, `content`,
  `kind`, `locations`, `rawInput`, `rawOutput`.

The MCP call handle is the `OperationEvent.correlationID`, the ACP
`toolCallId`, and the id scoping an elicitation (§16). A detached MCP call is
why `status` stays `in_progress` across turns. Mapping decisions:

- A dropped MCP connection rides as **`_lost`** (extensible status, §18), never
  flattened into `failed`, with "we do not know whether this ran" in the text.
- `rawInput` / `rawOutput` / `content` / `locations` need the **structured
  per-call record** from `FoundationModelsMCP`, not its model-facing rendered
  string, which is deliberately elided.
- **`ToolAnnotations` → `ToolKind`**: the right use of MCP's untrusted hints —
  a UI hint feeding a UI hint, never a gate.
- **`destructiveHint` / `openWorldHint` → `session/request_permission`**: where
  "hosts may gate on annotations" gets realized. The bridge never gates; this
  package may.

### 11.6 Reporting: `tool_call_update`

v2 has no `tool_call` create — `tool_call_update` is an upsert, and the first
update carrying an unseen `toolCallId` is the creation.

- **`status` defaults to `pending`** when a creating update omits it — a call
  that is already running must say `in_progress` explicitly or the client shows
  it queued.
- `ToolCallUpdate` requires only `toolCallId`; `title` SHOULD be on the first
  report.
- **The diff mapping trap**: ACP's `path` is absolute and **post-operation**.
  For `move` / `copy` (`DiffPathPairChange {oldPath, path}`), FileTool models
  it the other way round — map `FileChange.path → oldPath` and
  `FileChange.destinationPath → path` for those two kinds only; `add` /
  `delete` / `modify` map `path → path` unchanged. A naive `path → path`
  mapping silently shows the pre-rename filename on every move. (FileTool's
  shape is self-consistent — a translation note, not an upstream ask;
  `d7jwam5`.)
- `DiffChange` carries optional `fileType` / `mimeType` — populate where the
  tool knows them (drives client syntax highlighting). `ToolCallLocation`
  requires `path`, `line` optional (`GrepMatch` supplies both).
- `status`, `kind`, `title`, `rawInput`, `rawOutput` are all
  `x-deserialize-default-on-error`: malformed fields degrade rather than
  failing the notification.

### 11.7 `session/request_permission`

Shape: `{sessionId, title, options[≥1], description?, subject?}`; the prompt
copy (`title`/`description`) is separate from the structured `subject`.

- **`subject: tool_call` carries a full `ToolCallUpdate`, not a `toolCallId`**
  — the request itself conveys title, kind, `rawInput`, locations. Design
  consequence: **ask before emitting any `tool_call_update` for that call** —
  no "pending" call sits in the timeline for something the user may reject.
  Ask first, emit on approval.
- `subject: command` is `{command, cwd}` required, plus optional `toolCallId`
  and `terminalId`.
- `PermissionOption` requires all three of `optionId`, `name`, `kind`.
  `PermissionOptionKind` includes `allow_always` / `reject_always`, so
  **persisting always-decisions is this package's job** — bound to Shelltool's
  `ShellDecisionStore` with `.session` as the default scope (§2.5).
- Outcome is `cancelled` or `selected(optionId)`, with an `other` extension
  variant — **treat an unrecognized outcome as a refusal**, never an approval.

### 11.8 Agent-owned display terminals

Documented under Tool Calls and present in the vendored schema; **display-only**
— this is not the removed `terminal/*` client-execution surface returning. We
execute; the client renders. The schema:

| Schema type | What it is |
|---|---|
| `TerminalId` | unique id for an agent-owned terminal within a session |
| `Terminal` (a `ToolCallContent` variant) | display-only reference — `{terminalId}`; state and output arrive separately |
| `TerminalUpdate` (`session/update`) | upsert of terminal state; only `terminalId` required, other fields patch |
| `TerminalOutputChunk` (`session/update`) | appended bytes, independently base64-encoded |
| `TerminalOutput` | authoritative replacement snapshot of output bytes |
| `TerminalExitStatus` | `{exitCode?, signal?}`; its presence marks exited, even with neither known |

The mapping is `shell`'s user-visible payoff: Shelltool's `commandID` →
`terminalId`; incremental line streaming → `terminal_output_chunk` (base64 per
chunk — byte-faithful, no lossy text coercion); the stored record →
`TerminalOutput` (what a reconnecting client needs); command exit →
`TerminalUpdate.exitStatus` (the "exited even when unknown" semantics fit a
soft-deadline kill precisely). The tool call emits a `Terminal` content
reference; the bytes ride the terminal stream.

**Sequencing**: additive over ordinary tool-call content, so `shell` ships
text-in-`content` first and gains the terminal stream as a follow-up — but do
not design the shell tool's output path in a way that discards raw bytes before
the wire.

## 12. Content

**ACP's `ContentBlock` *is* MCP's** — the spec says so outright — so mapping an
MCP tool result's content into `tool_call_update.content` is shape-preserving
with no semantic loss (two Swift types in two packages, so not zero code, but
nothing to decide).

**Prompt capabilities are honest** (§5): text is the one unconditional MUST.
`image` / `audio` / `embeddedContext` are advertised only when the roster can
act on them — an absent capability beats accepting an image and dropping it.

**`resource_link` is not capability-gated** — it may arrive regardless
(required `name` + `uri`; optional `mimeType`, `size`, `title`, `description`,
`icons`). **Decision: resolve `file://` URIs inside the session's root set
through the `files` tool; refuse every other scheme and every out-of-bounds
path, with a reason.** Silently fetching an `http://` URI because it appeared
in a prompt is a request the user never made, from a process holding their
credentials; `file://` outside the root set is refused by `PathGuard` like any
other out-of-bounds path.

Field details worth not rediscovering: `TextContent` requires `text`;
`ImageContent` / `AudioContent` require `data` + `mimeType` (image additionally
allows an optional `uri`; audio does not); `EmbeddedResource` requires
`resource` — `TextResourceContents` (`text` + `uri`) or `BlobResourceContents`
(`blob` + `uri`). `Annotations` carries `audience`, `priority`, `lastModified`
— safe to ignore on input, worth populating on output where known.

## 13. Agent Plan

**No peer — off, stated honestly.** Router has no planning noun, and v2 only
says agents SHOULD report plans. We emit nothing, and say so.

For whenever a planner lands (FoundationModelsAgents), the asymmetry worth
knowing: **`plan_update` is the one update in v2 that replaces rather than
patches** — agents MUST transmit the complete entry list; clients MUST replace
prior contents entirely. An implementer who has internalized the upsert algebra
(§8.3) will get this exactly backwards. `PlanEntry` requires all three of
`content`, `priority` (`high`/`medium`/`low`), and `status`
(`pending`/`in_progress`/`completed`/`cancelled`), each `_`-extensible;
multiple concurrent plans are distinguished by `planId`, which every variant
MUST carry.

## 14. Slash Commands

*The commands' home. Slash commands are a session-level noun: `/compact` acts
on this session, and a skill discovered in this repo becomes a command in this
session only. One registry per session, assembled at session creation like
tools and instructions, re-published when a source changes.*

**The cross-package vocabulary is Extras' `SlashCommand`**: `name` /
`description` / `argumentHint` plus a two-kind `Body` — `.prompt(template:)`
expands into an ordinary model turn; `.action` runs code and streams text,
never touching the model. Contributors implement `SlashCommandProviding`
(`commands(workingDirectory:)` + optional `commandUpdates` stream) against the
leaf, never this package. Registry mechanics — merge, precedence, near-miss
matching, `commandUpdates` re-publication — are this package's.

### 14.1 Three sources, merged in precedence order

Later wins on name collision (logged); builtin names are reserved and never
overridden.

1. **Builtins** — this package's `.action` closures capturing the session:
   `/compact` (force compaction now), `/context` (fill, tokens, resolved
   context — kept for CLI ergonomics; the app binds `usage_update` instead,
   §8.4), `/memory` (print the assembled instructions with source headers),
   `/status` (session id, cwd, model/profile, transcript path), `/config`
   (print the effective configuration as commented YAML; `/config export
   home|project` writes it to that layer), `/help`. Frontend verbs (`/quit`,
   clear-as-new) stay out — composer affordances, same rule as queueing.
2. **Linked providers** — `SlashCommandProviding` conformers registered by
   catalog roster entries (§11.1): the *code-backed* lane. Only linked Swift
   can construct `.action` — the trust boundary; in-process code is already
   trusted as tools.
3. **Skills** — the *data* lane: `SKILL.md` files discovered and rendered by
   `FoundationModelsSkills`, surfaced through `SlashCommandProviding`. One
   skill = one `/id` command, pushed via `commandUpdates` as files change.
   Skill markdown is **data** and can only ever produce a prompt — a broken or
   malicious `SKILL.md` at worst yields a bad prompt under normal tool
   confinement; it can never become `.action`.

(MCP prompts are the reserved further source: `prompts/list` + `listChanged`
feed this same registry once wired.)

### 14.2 Where skills live, and the two integration gaps

**Skills resolve through `DotfolderStack(name: "skills")`** —
`$XDG_CONFIG_HOME/skills/` (default `~/.config/skills/`) and `<cwd>/.skills/`;
two layers, nearest wins by directory name. `skills` is simply the `<name>` of
a second stack — no new mechanism, same XDG rule.

- **The name is a constant, not our `<name>`, and that is the point.**
  [agentskills.io](https://agentskills.io) is an ecosystem format; a skill is a
  property of the user and the repo, not of whichever agent reads it.
  **`<name>` isolation does not extend to skills**: two agents built on this
  stack with different dotfolder names share one skill library — the intent,
  on the record because §2.1 makes a point of name-based isolation. (Precedent:
  project-level `AGENTS.md` is likewise unqualified, §3.2.)
- **We construct the stack; Skills takes what it is given** (§2.5):
  `FoundationModelsSkills` accepts its layer roots as a construction parameter
  (ordered, lowest first) and names no dotfolder convention. A host wanting a
  different layout passes different roots.
- **Trust**: both layers are untrusted — skill markdown renders under the
  untrusted template rules.
- **The `skills:` config section stays in the `<name>` stack** — content is
  shared, behavior is per-agent: `skills: false` disables discovery for this
  agent without touching anybody's library.

**Gap 1 — Extras' `SlashCommand.Body` needs a third case.** Skills fits
neither existing kind: not `.prompt(template:)` (Skills renders with its own
pipeline and argument model — handing the raw body to Extras' Stencil engine
would substitute under the wrong rules, silently), and not `.action` (defined
as never touching the model, whereas a skill's rendered body *becomes* the
turn). Needed: `case rendered(@Sendable (Invocation) async throws -> String)` —
the conformer renders, the dispatcher feeds the result to the model as it would
a `.prompt`. Filed on Extras as **`c2pad49`**. The trust boundary survives: a
closure can only be constructed by linked Swift. **Wanted, not blocking** — the
workaround is dispatching skill commands through `registry.call(id:arguments:)`
directly as a special case in our dispatcher; take it if `c2pad49` is slow,
prefer the case.

**Gap 2 — ACP flattens the parameter model.** Skills carries a real one
(`SkillParameter { name, position, required, variadic, placeholder }` +
`acceptsTrailingArguments`); ACP's `AvailableCommandInput` is a single
`{type: "text", hint: String}`. **Pass Skills' `argument-hint:` string through
verbatim as the hint** — it is already written in display syntax
(`<env> [region] [flags...]`), so the lossy step loses nothing a human reader
needs. Structured parameter prompting is an `_meta` extension if a client ever
wants it.

**Phasing** follows §11.3's roster: ship the command-provider half first; the
model-facing tool half follows its dependency chain. Any plan treating "skills
as a built-in" as one indivisible item will stall.

### 14.3 Dispatch — at the prompt owner

**The spec confirms this is the only place dispatch can happen**: commands
arrive as ordinary prompt text with a leading slash; there is no separate
invoke method. The prompt owners are this package's `prompt()` handler for the
wire and the frontends' composers for direct consumption — Router's sessions
know nothing of commands, and a `/compact` typed in an editor must never reach
the model as a prompt.

A leading `/name` routes through the registry *before* anything touches the
session:

- **`.prompt` (and skill) commands** expand (template + arguments) into a
  normal recorded model turn.
- **`.action` commands** stream output with no model turn and no transcript
  entries beyond what the action itself records (`/compact` its
  `CompactionSegment`; `/help` nothing).
- **Unknown `/name`** errors with near-matches — never a model turn. Frontends
  escape a literal leading slash.
- **A command may arrive with other content attached** (the spec allows
  `[text("/deploy prod"), resource_link(...), image(...)]`): `.prompt` and
  skill commands carry the extra blocks **into the expanded turn** — dropping
  them would discard the file the user deliberately attached. `.action`
  commands take no model turn, so attachments have nowhere to go: **refuse the
  invocation with a reason**. Silence is the one handling that is definitely
  wrong.

### 14.4 The ACP surface

On every registry change (skill discovered, template edited), the per-session
command set re-publishes — CLI autocomplete, app palette — and the conformance
fires **`available_commands_update`**. Advertising is a MAY and the list may
change at any time mid-session; `commandUpdates` feeds it. `AvailableCommand`
requires `name` + `description`, `input` optional; the text variant requires
`hint` (where the argument hint lands, §14.2); custom input types MUST begin
with `_`.

## 15. Session Config Options

v2 replaced session modes with typed config options in categories `mode` /
`model` / `model_config` / `thought_level` (`session/set_config_option`,
`config_option_update`; `session/set_mode` and `current_mode_update` are
gone). Model selection — Router's whole job — thereby gets a protocol-native
surface.

**Day one ships one real option, not an empty array**: a `select`, category
`model`, over the resident profile's `standard` / `flash` slots. Both are
already resident, so switching loads nothing and blocks on nothing — it
specifically does **not** need pooled residency (`kh01tv2`), which is only
required to switch *profiles*. Say in the option's `description` that this
selects among the profile's slots, so a user does not expect the whole
candidate list.

What we deliberately do not offer, each decided elsewhere: `model_config`
context size (derived from the model, §2.4), `mode` (no modes exist here),
`thought_level` (Router exposes no reasoning-level knob). Anything with no peer
stays absent.

**`currentValue` must track reality, which makes `config_option_update`
load-bearing.** Router's joint-fit genuinely picks among candidates by what
fits the host budget; when resolution lands on a different model than the
option advertises, push the update — otherwise the client's selector claims a
model the agent is not running.

Schema details:

- The list is **first advertised in the `session/new` / `session/resume`
  responses** (§7.4), ordered by priority — the selector must be constructible
  at session-creation time.
- **Array order is significant** — a priority list, not a set.
- **Both `set` and the push carry the complete state** (`required:
  ["configOptions"]`) — the full set every time, never a delta.
- `SessionConfigOption` requires only `configId` + `name`; `select` /
  `boolean` / `other` variants supply `currentValue` (and `options`). Grouping
  is a wrapper (`SessionConfigSelectGroup{groupId, name, options}`), not a
  field on options — we ship ungrouped. `category` is UX-only ("MUST NOT be
  required for correctness").
- **Every option MUST have a default**, so a client that ignores config options
  entirely still gets a working session.

## 16. Elicitation

**This package owns elicitation.** It is the only layer with a live
bidirectional channel to something that has a user. `FoundationModelsMCP`
defines the `ElicitationCoordinator` protocol and owns no UI; Router owns no
user channel (`SessionOutbox` is one-way outbound). The coordinator is
implemented here: **`ACPElicitationCoordinator`**, holding the
`AgentSideConnection`.

**A relay, not a translation** — MCP and ACP elicitation are near-isomorphic:

| MCP (swift-sdk) | ACP (`elicitation/*` — unstable schema) |
|---|---|
| `CreateElicitation` `.form(FormParameters{message, mode?, requestedSchema})` | `elicitation/create`, `mode: "form"`, `message`, `requestedSchema` |
| `.url(URLParameters{message, mode, url, elicitationId})` | `mode: "url"`, `message`, `url`, `elicitationId` |
| `Result.Action { accept, decline, cancel }` | `action: accept \| decline \| cancel` (+ optional `content`) |
| `notifications/elicitation/complete { elicitationId }` | `elicitation/complete { elicitationId }` (agent → client) |

Both directions of MCP elicitation route through the one coordinator: a server
pausing mid-tool-call, and the model asking via `MCPElicitationTool`.

**Requirements:**

- **Scope every request**: `sessionId` plus `toolCallId` — the MCP call handle
  maps to it — so the client can show *which* tool call is asking, including a
  detached long-running one that would otherwise prompt out of nowhere; or a
  `requestId` for interactions outside a session.
- **Gate on capability, degrade honestly — and the gate is `_meta`.** Stable
  v2's `ClientCapabilities` carries only `_meta`, so elicitation support is a
  `_meta`-negotiated extension for as long as `elicitation/*` is unstable.
  Absent means unsupported (§5). When the needed mode is unsupported, return
  MCP **`decline` with a clear reason** — never a lossy squeeze into
  `session/request_permission`, which is options-based and cannot carry a
  `requestedSchema`.
- **Relay URL-mode completion**: create → accept → `elicitation/complete` is a
  three-message flow; forward MCP's completion notification straight through —
  the ids match by design.
- **Security duties** (ours as the agent): form mode MUST NOT request secrets;
  URL-mode credentials MUST NOT come back over ACP; **agents MUST NOT fall back
  to form mode when URL mode is unavailable** — URL mode exists because the
  data is sensitive, so the only correct response to "URL unsupported" is to
  decline; the agent MUST verify the authenticated user identity matches
  between initiation and completion; HTTPS outside development; no prefetching.
- A client returning `-32602` (unsupported mode) is reporting **our** bug — we
  should not have requested it. `elicitationId` must be unique among
  *outstanding URL elicitations on the connection* (narrower than global), and
  `elicitation/complete` goes only to the client that received the create —
  key on the connection, not the session.
- **Do not stall the model.** Every round-trip is wrapped in Router's
  `awaitingUser { }` paired with `state_update: requires_action` — the gate
  release and the state transition are two halves of one action (§8.2).

**Gating and the interim.** `elicitation/create` / `elicitation/complete`
exist in the unstable schema as **method names only** — no generated types, no
handlers (and the docs' `capabilities.elicitation` field does not exist in the
stable schema). The wire package must land the types and client-side handler
entry points first, so **this is not day-one scope**. Interim:
`FoundationModelsMCP`'s coordinator gets a non-ACP fallback that declines every
elicitation with a clear "this host cannot ask you questions yet" reason —
honest, and it unblocks the MCP built-in without waiting on the unstable
surface.

## 17. Transports

**Framing** (protocol MUSTs, not house style): messages are UTF-8 JSON-RPC
delimited by `\n` with **no embedded newlines** and no content-length header.
The agent **MUST NOT write non-ACP content to stdout** — the gated integration
test (§20.1 tier 3) asserts a MUST. stderr is free for logging; the client may
capture, forward, or ignore it.

**Consumers**: external clients speak ndJSON over stdio (`<cli> acp` — the
production CLI and the ACP agent are the same binary); the Mac app uses
`InMemoryTransport.pair()` in-process (§19). Full duplex, not
request/response: `session/prompt` returns `{}` immediately and the entire turn
arrives as notifications on the same pipe (§8.1).

**What the wire package already handles** (do not reinvent): frame
serialization (`StdioTransport` writes under a lock — concurrent sessions
cannot produce a torn line), respond-then-notify ordering
(`afterRespondingToCurrentRequest(_:)`), and lifecycle (the client launches the
agent as a subprocess and terminates it; the agent reads until stdin EOF — no
teardown handshake).

**Batching** is permitted by the spec, but "initialize, auth, and session
operations SHOULD NOT be batched" — which covers essentially everything this
agent handles, so batch handling stays the wire package's concern and never
becomes a sequencing hazard here.

**The one hazard to defend against actively: subprocess stdout.** `shell`
spawns children, and a child that *inherits* the agent's stdout writes directly
into the ACP frame stream — corruption no unit test catches, because the tool
behaved correctly. Shelltool captures child output rather than inheriting it;
tier 3 (§20.1) proves it end to end.

## 18. Extensibility

- **All extensions go in `_meta`, never beside it.** Implementations MUST NOT
  add custom fields at the root level of spec-defined types — all root names
  are reserved for future protocol versions. This covers the elicitation
  capability gate (§16) and anything else we contemplate. Root-level
  `traceparent` / `tracestate` / `baggage` are reserved for W3C trace context —
  honor them if we ever emit tracing.
- **`_`-prefixed values are the extension mechanism for extensible enums.**
  Values beginning with `_` are implementation-specific; unknown
  non-underscore values are reserved for future ACP variants and MUST NOT be
  treated as custom extensions. This is what makes `_lost` (§11.5) legitimate
  and a bare `lost` a name-grab.
- When proxying, unknown values SHOULD be preserved; unknown variants SHOULD
  fall back to generic UI rather than being dropped.

---

# Part III — Beyond the protocol

## 19. Frontends: the shared-consumption contract

Three consumers share this composition: the Mac app, the CLI, and any ACP
client (Zed, editors). The app and CLI are out of scope to *build* here; every
contract is in scope to *prove*.

- Both construct this package's composed agent with the **same dotfolder
  name** (§2.1) — that single string is what makes config and transcripts
  shared.
- **The CLI is a thin ArgumentParser wrapper**: parse args → construct agent →
  render the session event stream. `Examples/acp-agent` (§20.2) is this CLI in
  miniature and doubles as the living contract test; the production CLI grows
  in its own repo from a copy of it, and `<cli> acp` speaks ndJSON over stdio.
- **The Mac app is itself an ACP client, in-process** via
  `InMemoryTransport.pair()` — the same interface Zed uses, over a different
  transport. It lands the ACP event stream in `@Observable` containers and
  binds those to SwiftUI. Binding Router directly would create a second,
  drifting path to the UI beside the one every external client sees.
- **Infrastructure state still comes from Router directly.**
  `ResolutionProgress` (model download/load, residency) is not session content
  and ACP has no notification for it. The split is the rule: **session content
  flows over ACP; infrastructure state comes from Router.**
- The history browser uses `TranscriptStore.allProjects()` /
  `sessions(inProject:)`.
- **Sandboxing**: sharing `~/.config/<name>` and arbitrary project directories
  is incompatible with the App Sandbox. The Mac app ships **non-sandboxed** (a
  developer tool operating on arbitrary repos — the norm for the product
  class; still notarized, hardened-runtime). If sandboxing ever becomes
  mandatory: security-scoped bookmarks per project plus moving the home layer
  to `~/Library/Application Support/<name>/` with the CLI honoring the same
  path — the `DotfolderStack` seam localizes the change. Decide before the app
  ships; nothing in this package blocks on it.

### 19.1 The record, the interface, and the observable container

Three representations in a strict derivation order, never reversed:

```
Transcript (FoundationModels)          THE RECORD — authoritative, non-monotonic
   |  Router projects changes
SessionEvent  +  SessionProjection     keyed on Apple's own Transcript.ToolCall.id
   |  this package maps (§8.4)
ACP session/update                     THE INTERFACE — the wire stream
   |  InMemoryTransport (in-process) or stdio (external clients)
ACP Client conformance = @Observable   SwiftUI binds this
```

- **ACP is a projection, never a second record.** Every `session/update` must
  be derivable from the transcript. The corollary that makes it safe: an
  observable container must be **rehydratable** via `session/resume` +
  `replayFrom: start` (§7.4), not merely accumulated from a live stream it
  might have joined late.
- **Coalescing is a requirement, not an optimization.** `textDelta` arrives at
  token rate; applying each to an `@Observable` on the main actor thrashes
  SwiftUI. Batch deltas and flush at display-rate cadence, appending into the
  in-flight message.
- **The transcript stays directly reachable** — the session (and its
  `Transcript`) is exposed to the frontend for authoritative inspection,
  history, and debugging. A second *view* of a derived-from source, not a
  second source.

## 20. Testing

### 20.1 The test ladder — five tiers, only two need a model

The organizing question: **"do the tools work" and "does the model use the
tools" are different questions** — only the second needs a model.

| Tier | Model | Client | Tools | Gated | Answers |
|---|---|---|---|---|---|
| 0 — unit | — | — | — | no | do the tools work in isolation *(done upstream: FileTool 461, Shelltool 298, Router 624 tests)* |
| 1 — golden conformance | scripted | recording sink | fake | no | is the wire shape right — ordering, upserts, replay |
| 2 — tool integration | scripted | recording sink | **real** | no | do real tools work through the real conformance |
| 3 — stdio contract | scripted | subprocess | real | yes | does framing survive a real process boundary |
| 4 — eval | **real** | in-process | real | yes | does the model *choose* to use tools, and succeed |

**There is no "fake client" to build — `ClientSideConnection` is the client.**
A `Client` conformance is roughly ten lines:

```swift
private struct RecordingClient: Client {
    let updates: UpdateCollector
    func sessionUpdate(_ n: UpdateSessionNotification) async { await updates.append(n) }
    func requestPermission(_ p: RequestPermissionRequest) async throws
        -> RequestPermissionResponse { .init(outcome: .selected(optionId: "allow")) }
}
let (clientEnd, agentEnd) = InMemoryTransport.pair()
let client = await ClientSideConnection(stream: clientEnd) { _ in RecordingClient(updates: c) }
```

A **sink**, not a simulation. Everything above tier 0 uses these same ten
lines.

**Tier 2 is the one that answers the question.** Real `ToolCatalog`, real
`FileTool` and `Shelltool`, real `RoutedACPAgent`, real `session/new(cwd)`
against a temp directory — with the *model* scripted: inject a `ModelLoader`
whose `LoadedLLMContainer.makeSession` returns a `LanguageModelSessionBackend`
emitting a predetermined tool call (Router's own `ScriptedOverflowBackend`
proves the pattern; no upstream change). No MLX, no download, no
Apple-silicon gate — it runs in CI on every commit. What only tier 2 proves:

1. **Composition** — `ToolCatalog` constructs each tool with the right
   `ToolContext`: root set from `cwd` + `additionalDirectories`, that tool's
   decoded config section.
2. **Confinement through the protocol** — ask `files` for a path outside the
   root set and get a refusal, driven from the client end.
3. **Projection** — a real tool call becomes a correct `tool_call_update`:
   stable `toolCallId`, `in_progress` → `completed`, populated `locations`,
   `rawInput`/`rawOutput`, `title` on first report.
4. **Turn ordering** — `{}` → `user_message` → `running` → tool updates →
   `idle(end_turn)` (§8.1).
5. **Enable/disable** — `shell: false` in project config means no shell tool
   reaches the session, verified from the client end.

**The rule that makes tier 2 trustworthy: assert the filesystem, never the
transcript.** If the test says a file was written, read it from disk — do not
believe a `tool_call_update` that claims success. Same discipline as §20.3's
evaluators; it is what separates catching a broken tool from catching a broken
*report* of a tool.

**MCP gets tier-2 coverage for free** once `4egfvw3` lands:
`FoundationModelsMCP` ships `MCPTestServerCLI` and a `ScriptedServer` — spawn a
real server process, list its tools, call one, assert the `tool_call_update`
correlation holds.

**Tiers 3 and 4 stay gated and stay small.** Tier 3 exists for exactly what
tier 2 cannot see: real process boundaries — stdout carrying nothing but
ndJSON while `shell` runs subprocesses writing to *their* stdout, and no
embedded newlines (both protocol MUSTs, §17). Tier 4 is §20.3.

### 20.2 `Examples/acp-agent` — the example program and the tier-3 fixture

**One executable serves both purposes, deliberately** — the family convention
is an `Examples/` directory of runnable programs, the example this package owes
is "how do I build an ACP server CLI on top of this," and that is precisely
what tier 3 needs to spawn. Written twice, the example would rot while the
fixture stayed green.

`Examples/acp-agent/main.swift`, small enough to read in one sitting — the
composition is the lesson:

```swift
// 1. the dotfolder name is the frontend's choice (§2.1) — everything else derives
let agent = try await RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)

// 2. serve ACP over stdio; stdout is sacred, logs go to stderr
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in agent }
await connection.run()
```

It must demonstrate: choosing the dotfolder name and what it controls; serving
over `AgentSideConnection(stream: .stdio)`; logging to stderr only; where a
frontend adds its own tools to the merged roster (§11.1). It must *not* grow
into a second product — no argument parsing beyond stdio serving, no rendering,
no config wizardry. An example written as a read-request/write-response loop
would deadlock the moment it emitted a mid-turn update — the full-duplex shape
(§17) matters pedagogically as much as functionally. (The wire package's
`acp-test-agent` is the contrast: it answers `initialize` and nothing else;
ours composes the real runtime and real tools.)

### 20.3 Evaluations — `PythonCLIEvaluation`

The end-to-end coding eval belongs to the layer that composes the roster
(Router keeps its compaction-focused eval over sample tools). Drives real
`files` + `shell` through a real multi-turn build task on Apple's Evaluations
framework (swift-testing native), gated on Apple silicon + real models +
network:

1. **Subject**: `subject(from sample:)` creates a fresh temp workspace (the
   session's `workingDirectory` and the tools' confinement root), wires
   recording to a temp location, constructs the composed agent with real
   `files`/`shell` and the coding instructions, runs to completion, returns
   workspace path + transcript + run stats.
2. **Dataset**: `ArrayLoader` of `ModelSample`s — variants of "build a small
   Python CLI" (`pyproject.toml`, a third-party package such as `click`, the
   CLI, pytest tests, a project-local venv, pytest green, run it), with
   `expected` carrying the fixed input/output pair. 20–30 hand-written samples
   per Apple's guidance; scale later with `SampleGenerator`.
3. **Evaluators — mechanical, re-verified outside the agent**, never trusting
   the transcript's claims; one `Metric` each: `PytestGreen` (re-runs pytest in
   the venv, exit 0), `CLIRuns` (executes the CLI against `expected` and checks
   output), `FilesPresent`, `ToolTraffic` (transcript contains both `files`
   and `shell` calls).
4. **Aggregation**: `MetricsAggregator.computeMean` per metric; the `@Test`
   asserts mean pass rates against thresholds. Turn count, tool-call counts,
   token usage ride along, keyed by the resolved model from `manifest.json`.

Isolation: everything inside the temp workspace — venv within it, no
system-Python mutation, no network beyond package install; workspace deleted
after grading (transcripts retained for failed runs).

## 21. Upstream dependencies

| Id | Package | What | Status |
|---|---|---|---|
| `f9q2338` | FoundationModelsShelltool | build `ShellPolicy` from values, host-owned persistence (§2.5); its Extras dependency disappearing is the completion signal | **open** — interim: inject URLs at our dotfolder |
| `c2pad49` | FoundationModelsExtras | third `SlashCommand.Body` case, `.rendered` (§14.2) | **open** — workaround available, prefer the case |
| `939nnzx` | FoundationModelsFileTool | multi-root `PathGuard` (§7.2) | **in progress** — the only blocker for `additionalDirectories` |
| `4egfvw3` | FoundationModelsMCP | needed for tier-2 MCP coverage via `MCPTestServerCLI` (§20.1) | open |
| — | FoundationModelsRouter | `CompactionResult` carries message-level identity (§8.5) | **open** — required for compaction upserts |
| — | FoundationModelsRouter | in-flight turn cancellation (§8.6) | **open** — until then, "we stopped listening" |
| — | FoundationModelsACP | generated types + client handler entry points for `elicitation/*` (§16) and `mcp/*` tunnel (§11.5) | open — both unstable-schema |
| `ke41yth` | FoundationModelsRouter | per-session recording root, flat `<root>/<sessionId>/` layout (§4.1) | **landed** |
| `kh01tv2` | FoundationModelsRouter | pooled, reference-counted model residency → per-project profiles (§7.1) | **landed** |
| `6j4bven` | FoundationModelsRouter | checkpoint-aware session restore feeding `session/resume` (§7.4) | Router board |
| M1–M3, M5 | FoundationModelsSkills | the `/id` command half (§14.2) | plan-only |
| M4 (+ Operations 2/4/5, MetadataRegistry M1–M4) | FoundationModelsSkills | the model-facing tool half (§11.3) | plan-only; follow-up |
| `d7jwam5` | FoundationModelsFileTool | *note, not an ask*: rename/copy path mapping is a translation here (§11.6) | — |
