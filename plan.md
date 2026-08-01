# Plan: FoundationModelsACPAgent — the composed agent over the Router runtime

## 1. What this package is

The wire and the composition are two different packages. The sibling package
[`../FoundationModelsACP`](../FoundationModelsACP/plan.md) is the pure ACP
wire. It has zero dependencies. It contains the generated types, the role
protocols, the connections, and the ndJSON framing. **This package is the
agent.** It is a layer over **FoundationModelsRouter**, the family runtime.
Router sessions fold themselves (`makeSession(budget:compactionPrompt:)`).
Router meters tokens, streams events with correlation ids, and records each
session. This package owns everything that the runtime refuses to own: file
I/O, dotfolders, the command registry, the tool roster, and the `Agent`
conformance. The conformance has the name **`RoutedACPAgent`**.

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

**Dependencies.** This package depends on the ACP wire, Router, and Extras. It
also depends on the four sibling packages of the built-in roster, from day one:
**`FoundationModelsFileTool`** (`files`), **`FoundationModelsShelltool`**
(`shell`), **`FoundationModelsMCP`** (`mcp`), and **`FoundationModelsSkills`**
(its slash-command half; §14.2). Only this package gives names to tool
packages. The runtime may not do this. No cycle is possible: no tool package
depends on this one.

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

**The conformance is a translation, not a construction.** Each ACP noun names
its peer in this stack. If a noun has no peer, we set that capability off,
honestly. We do not fake it. ACP turns operate Router's sessions through the
prompt owner. Thus each runtime function operates over ACP with zero
wire-specific code: automatic compaction (proactive and reactive), budgets,
retry, chokepoint recording, confinement, and the context meter. The lower
layers do not become agents: `RoutedSession` stays Router's wire-free session
surface. `LanguageModelSession` stays Apple's conversation primitive. (Note on
names: the wire package declares the protocol-role `Agent`. No other type here
has the name `Agent`. Thus `RoutedACPAgent: Agent` is not ambiguous.)

**We aim at ACP v2 only.** The stable v2 method set is `initialize`,
`auth/login`, `auth/logout`, `session/new`, `session/resume`, `session/list`,
`session/delete`, `session/close`, `session/prompt`, `session/cancel`,
`session/set_config_option`, `session/request_permission`, `session/update`.
`elicitation/*`, `mcp/*`, and `session/fork` are in the **unstable schema
only**. We plan them, but we gate them (§16, §11.5, §7.5). `session/list` /
`resume` / `close` are baseline in v2. Each agent that supports sessions must
supply them. "Capability off" is not available for them.

**One identity goes through the full stack.** Apple's `Transcript.ToolCall.id`
= Router's `SessionEvent.toolCall(id:)` = ACP's `toolCallId` = the MCP call
handle = `OperationEvent.correlationID` = `AgentSpawn.parentToolCallId`. This
is one stable key across five layers. The key correlates the wire's tool
updates. It scopes elicitations. It keys SwiftUI `ForEach`. It makes a
sub-agent's transcript reachable from the tool call that the client saw.

Part I below gives the agent-side foundations: configuration, instructions,
transcripts. Part II gives the protocol surface. Part II is **parallel with
the [ACP v2 spec](https://agentclientprotocol.com/protocol/v2/overview)**: one
section for each spec page, in the spec's order. Tools are in **Tool Calls**
(§11). Slash commands are in **Slash Commands** (§14). Session configuration
is in **Session Config Options** (§15). Part III gives the frontends, the
tests, and the upstream dependencies.

---

# Part I — Foundations

## 2. Configuration

### 2.1 The dotfolder name

**The frontend supplies `<name>`. It is a construction parameter of the
agent.** The name is a bare word with no leading dot (`"coding"`, `"acme"`).
No layer below this one contains the name. Router, the wire, and the tool
packages do not see it. Two frontends that pass the same name share
configuration and transcripts. Two frontends that pass different names are
fully isolated on disk. The Mac app and the CLI pass the *same* name (§19). A
test or a demo passes its own name and touches nothing.

The name goes to exactly three consumers:

| Consumer | Effect |
|---|---|
| `DotfolderStack(name:)` | the two config locations below |
| transcript root (§4) | `<cwd>/.<name>/transcripts/…` |
| `profile.name` default | falls back to `<name>` when unset |

Each downstream component receives *values* that come from the name. No
downstream component receives the name itself.

**Validation is necessary, because this string becomes a path component.**
Refuse an empty name. Refuse a name that contains `/`, `\`, or a path
separator. Refuse `.` and `..`. Refuse a name that starts with `.` (the
project layer adds the dot; the caller does not supply it). A bad name is a
hard error at construction, not a warning. A name that gets out of its
directory is a config-file-writing primitive aimed at an unknown path.

### 2.2 The stack

`DotfolderStack` is **Extras'** type:
`init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)`.
The `userDirectory` and `environment` parameters are injectable. Thus tests do
not touch the real home directory. This package does not pass a
`defaultsDirectory`. The layers follow, with the lowest precedence first:

1. **Builtin defaults are in code, not on disk.** The property defaults of
   `AgentConfiguration` *are* the default configuration: a selected
   coding-model profile that operates correctly on a 16 GB machine
   (`recording.level: full`, `transcripts.location: project`). There is no
   shipped `config.yaml`. There is nothing to materialize on the first run.
   There is no defaults directory. Layer 1 is code for each artifact: the
   config defaults, the compiled-in `Instructions.md` (§3.1), and the builtin
   slash commands (Swift `.action` closures, §14.1). One rule stays important:
   **a change of behavior must not make a rebuild necessary.** A file can
   shadow each code-level default. `/config export` (§14.1) and
   `<cli> instructions --eject` (§3.1) write that file for you.
2. **User layer: `~/.config/<name>/`** (no leading dot). Use
   `$XDG_CONFIG_HOME/<name>/` when that variable is set *and* absolute. If
   not, use `~/.config/<name>/`. This layer holds machine-wide preferences.
3. **Project layer: `<project>/.<name>/`** (leading dot). This layer holds
   per-repo overrides. `<project>` is the **session working directory of the
   agent** (ACP's `session/new(cwd)`). It is not the cwd of the process. This
   is important: one process serves many sessions in different repos. Thus
   this layer resolves *per session*. Two concurrent sessions can correctly
   see different project config.

The dot position obeys the convention of each directory:

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
| *(no per-tool config files — tools take **objects**, §2.5)* | — | — | `decisions.yaml` lands here; this package supplies its location (§2.5) |

`AGENTS.md` is the one **additive** row. It answers "in which order do the
files compose". Each other row answers "which layer wins".

### 2.4 Schema and loading

**The `AgentConfiguration` schema** contains `profile` (standard/flash/
embedding slots), `tools` (built-in sections + `mcp`, §11.2), `permissions`
(the ask-before-running mode, §11.7), `recording`, `transcripts`, and
`compaction`. There is **no `instructions` section**. The
system prompt is a markdown file (§3.1). The context size comes from the
model. It is not configurable, and this is intentional.

**Extras does the loading.** `LayeredYAMLDocument` loads the files. It renders
them through the template engine. The builtin defaults render as trusted. The
user and project layers render as untrusted. (`{{ env.TOKEN }}` keeps secrets
out of committed files.) It merges the layers with the family's one rule. It
returns a value tree with source data for each key. This package decodes the
tree with `Codable`. An unknown top-level section causes a warning. An unknown
key in a known section causes an error. Router does not see the configuration.
Sessions receive values.

### 2.5 Tool packages take objects, not config files

**Only this package reads configuration. Tool packages receive constructed
values.** No tool package reads its own config file. No tool package names a
dotfolder convention. The mechanical test: **a tool package that depends on
Extras' `DotfolderStack` does configuration that it must not do.**

| Package | Takes | Status |
|---|---|---|
| `FoundationModelsFileTool` | `root`, `additionalRoots`, `readOnly`, `allowSymlinks` | ✅ complies |
| `FoundationModelsMCP` | server descriptions | ✅ complies |
| `FoundationModelsSkills` | layer **roots** (ordered, lowest first — §14.2) | ✅ by design: for skills the folders *are* the data (content discovery, not self-configuration) |
| `FoundationModelsShelltool` | a `ShellSecurityConfig` value + a `ShellDecisionStore` with host-supplied decision-file URLs | ✅ complies — **`f9q2338`** landed 2026-07-29; the Extras dependency is gone (the completion signal). The file-based route stays for standalone use |

**`tools: shell:` in our `config.yaml` is the full story.** We decode it as
Shelltool's own option type (§11.1). This package then constructs the policy
value:

```swift
ShellPolicy(rules: ShellPolicy.builtinRules.merged(with: configured), decisions: store)
```

Shelltool contains the compiled builtin denials. Its values initializer checks
`builtinRules.deny` unconditionally, before the host rules. Thus **no config
layer can remove them**, and the host cannot forget the merge. We merge
`builtinRules` in anyway: then the composed value describes the full rule set,
for print and inspection.

**One intentional exception to §2.2's precedence exists, and it is
security-shaped: denials union across layers.** A project-layer `deny` list
must not replace the user's machine-wide list. If it did, an open repo could
silently remove "never run `rm -rf`" from a user's machine. Denials are a
floor: the builtin, user, and project denials all apply. `allow` and `ask`
obey the usual override. Our codec applies this rule. This section states it.

**`decisions.yaml` is state, not configuration.** The agent writes the
`allow_always` / `reject_always` answers. The user does not author them.
Shelltool defines the decision vocabulary and the match logic. **This package
decides where the data persists, and if it persists**:
`ShellDecisionStore(userDecisionsURL:projectDecisionsURL:)` takes the
decision-file locations from the host. We point them at our dotfolder layers,
or pass `nil` for no persistence. The `.session` scope stays in memory,
written nowhere. Keep `.session` as the default scope for a remembered
answer. The project dotfolder is **committed** (§4). A click on "always
allow" must not silently make a tracked file change in a shared repo.

## 3. Instructions

### 3.1 The system prompt — `Instructions.md`

**The prompt is one markdown file. It resolves through the usual layers. The
nearest layer wins, and it replaces the full file:**

| Layer | Location | Notes |
|---|---|---|
| 1 | **compiled in** | the guaranteed floor; never edited, only shadowed |
| 2 | `~/.config/<name>/Instructions.md` | machine-wide replacement |
| 3 | `<project>/.<name>/Instructions.md` | per-repo replacement |

The compiled-in floor is necessary. The prompt is the one artifact for which
*nothing* is not a valid value. Absent config gives defaults. An absent
`skills/` gives no commands. But an absent system prompt gives an agent with
no instructions, silently.

**Replacement is wholesale. Addition has its own lane.** A layer-3
`Instructions.md` replaces the full base. A merge of prose has no meaning.
Additive instructions go in `AGENTS.md` (§3.2). The two lanes:
**`Instructions.md` replaces, `AGENTS.md` adds.**

**Discoverability obligations** (the cost of a compiled-in floor): DocC/README
show the builtin text verbatim. The CLI can print the assembled prompt. The
CLI can also **eject the builtin** to a layer-2/3 path
(`<cli> instructions --eject`). This is the counterpart of `/config export`.
Think about a `/instructions export home|project` builtin. It gives symmetry
from inside a session.

**Extras does the resolution and the rendering. This is not a special
lookup:**

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

- **We do not walk layers ourselves.** `content(_:)` *is* the resolution rule.
  (`nearest(_:)` / `locate(_:)` are available for diagnostics.)
- **The source gives the trust level. Configuration does not.** `nil` means
  that the floor renders as trusted. Each file from disk renders as untrusted.
  Layers 2 and 3 are both untrusted. Thus there is no third case.
- **Partials also stack, and that part is useful.** A project can replace one
  partial and keep the full prompt. This gives back the granularity that
  wholesale replacement removes. It does not add a merge rule for prose.

The untrusted render is validated and has no side effects. It has no
filesystem or exec reach. Budgets meter the include depth, the loop
iterations, and the output size. Thus a hostile `Instructions.md` in a cloned
repo has the same limits as each other untrusted document.

### 3.2 Agent-instructions files — `AGENTS.md` via Extras' `AgentsMd`

These files are context, not memory. Per [agents.md](https://agents.md/),
`AGENTS.md` is "a README for agents". Nothing here keeps data across sessions.
The discovery walk is Extras' `AgentsMd`. (FoundationModelsAgents uses the
same walk for sub-agent instructions.) This layer consumes the walk.
Resolution is **per session, relative to the session working directory**. It
is never per process.

At session creation, this layer assembles two sources:

1. **User-level**: `~/.config/<name>/AGENTS.md` through
   `DotfolderStack.content("AGENTS.md")`. This is our extension. The spec has
   no home-directory concept. It goes first, as the most general text.
2. **Project-level**: `AgentsMd.documents(from: cwd)`. This walk goes from the
   repository root down to the session cwd. At each directory it reads the
   first of `AGENTS.md`, `AGENT.md` (the spec's migration alias), and
   `CLAUDE.md` (an ecosystem-compatibility alias). It reads one file for each
   directory. The outermost file goes first. Thus the file nearest to the cwd
   goes last (the spec: "closest one takes precedence").

**Assembly order:** the base prompt (`Instructions.md`, §3.1) → the user-level
`AGENTS.md` → the project-level documents (root → cwd). The nearest
`AGENTS.md` has the last word. A header with the absolute path of each file
divides the files. Thus the model, and each reader of the session
`instructions`, can attribute each line. A missing file is only absent. A file
that is present but not readable causes a logged warning, not a hard error.
This is content, not configuration. Each document renders through the template
engine (untrusted) before assembly.

This layer reads the assembled text one time, at session creation. It folds
the text into the `instructions` value for `makeSession`. The text stays for
the session's life. A new session gets the edits. Compaction does not fold
instructions (Router's invariant). Thus this context stays through each fold,
by construction. Router does not know that this occurred.

## 4. Transcripts

### 4.1 Location: project-local, keyed by ACP session

**`<cwd>/.<name>/transcripts/<sessionId>/`.** A transcript is project context.
It is not a personal activity log. The work that the agent did on a repo goes
with the repo. It travels when the repo travels. A colleague who clones the
repo gets it.

```
<cwd>/.<name>/                       # the same project dotfolder as config.yaml
    config.yaml                      # committable — team settings
    transcripts/
        .gitattributes               # linguist-generated + merge=union (committed)
        sessions.jsonl               # this project's session index
        01K3G.../                    # ACP sessionId
            transcript.jsonl
```

- **There are no project slugs.** The directory is the identity. (The
  `-Users-…` slug scheme stays only for `transcripts.location: home`.)
- **The ACP session is the organizing key. The Router run is not.** A
  routerId is provenance, not structure. Record it as metadata in the session
  directory. Do not use it as a path segment. Router's
  `recordingDirectory(forSessionId:recordingRoot:)` (landed as `ke41yth`)
  gives the flat `<root>/<sessionId>/` layout. `makeSession(recordingRoot:)`
  receives `<cwd>/.<name>/transcripts/`.
- **`transcripts.location` gives the override**: `project` (default), `home`
  (shared root + slugs), or an absolute path.

### 4.2 One ACP session is one root Router session — and nothing else is

**The ACP `sessionId` *is* the ULID of the root Router session.** It is the
same identifier, serialized. It is not a mapping. (ACP's `SessionId` is an
opaque string. A mapping table can drift. The first symptom would be a
`session/resume` that restores the wrong conversation.)

Router has two kinds of descendant. Keep them different:

| | What it is | How it links | Directory |
|---|---|---|---|
| **fork** — `fork(workingDirectory:)` | a branch of the same conversation | `parentId` | nests: `<rootId>/<forkId>/` |
| **agent spawn** — `AgentSpawn(parentSessionId:parentToolCallId:)` | a sub-agent launched by a tool call | `parentToolCallId` — the spawning tool call | its own directory; linkage is the id, not nesting |

**No descendant is an ACP session.** Forks and sub-agents do not receive an
ACP `sessionId`. They do not show in `session/list`. They do not accept
`session/prompt`. To the client, a sub-agent is a thing that the agent *did*:
a tool call with a kind and content. It is not a second conversation.
`AgentSpawn.parentToolCallId` is the same id as ACP's `toolCallId` (§1). Thus
the tool call that the client saw gives access to the sub-agent's transcript.

Two rules come from this:

- **`session/list` shows only roots**: a session is listable if
  `parentId == nil` and `agentSpawn == nil`. The sidecar has both facts. Thus
  the cost is one predicate.
- **`session/close` closes the tree**: a fork or sub-agent that operates is
  part of the session's work (§10.1).

**Where a sub-agent's transcript goes:** under the project root of the
sub-agent's own cwd. A sub-agent in a different repo goes in *that* repo's
transcripts. `parentToolCallId` links it, as a sibling. Forks share the parent
conversation. Thus forks stay nested under the parent, as before.

### 4.3 Transcripts are committed — the transcript is the source

**We commit transcripts. We do not ignore them.** The transcript is the new
source. The code is its output. The prompts, decisions, and corrections that
made a change are the durable artifact. The diff is their result. By default,
nothing under `.<name>/` is ignored. The results follow. Each is a design
obligation:

- **Per-session directories make this mergeable.** Two developers make two
  `sessionId` directories. Thus there is no conflict, by construction.
  `sessions.jsonl` is the one shared file. It is **append-only, with one
  self-contained record on each line**. `.gitattributes` sets `merge=union` on
  it. Think of it as a cache: a scan of the session directories can rebuild
  it. Thus a damaged index is not load-bearing.
- **Mark the files as generated.** `.gitattributes` sets
  `linguist-generated=true` on `transcripts/**`. This keeps the files out of
  language statistics. PR review folds them by default.
- **Repo size is a real cost. There is no clean mitigation.** At
  `RecordingLevel.full`, a transcript contains the full contents of each file
  that a tool receives. `recording.level` is the control, and it is
  per-project. A repo can select `metadata`. Then it keeps the shape of its
  history without the payload. Say this in the docs, clearly: full transcripts
  are the default because they are the valuable thing, and they are not free.

### 4.4 No redaction — deliberately

**We record transcripts verbatim. There is no redaction pass. This package
does not configure Router's `redact:`.** The assumption, written so that you
can check it: this is a development tool, in development trees, with
development credentials. The repo's own visibility is the control for a repo
whose history must stay private. Two positive reasons:

- **Redaction damages the source.** A pattern matcher that rewrites a wrong
  line makes a record that does not tell what occurred.
- **Partial redaction causes false confidence.** No pattern set catches each
  secret. Persons then think a "redacted" transcript is safe to publish.
  Verbatim-and-private is an honest position.

**`recording.level` stays the control for repos that want less.** `metadata`
records the shape without the content. `off` records nothing. Commit the level
in the project layer. Then it applies to each person who works there. If the
assumption stops being true (a public repo, a regulated codebase, production
credentials), the answer is `recording.level`, not redaction. One line in the
docs makes the premise visible.

### 4.5 Cross-project browsing — the project registry

The app's cross-project session browser asks "what did I do in repo X last
week?". **Keep a project registry in the user layer**:
`~/.config/<name>/projects.jsonl`. Append to it when a session starts in a cwd
that is new: the absolute path, first seen, last seen. **It holds paths only,
never content.** It is a cache, not a record: you can regenerate it, and you
can delete it. Skip stale entries on read.

### 4.6 `TranscriptStore`

This is the read side that the frontends and `session/list` (§9) need:
`sessions(inProject:)` (a plain directory read), a paged variant for cursor
pagination (§9), `allProjects()` through the registry, and
`transcript(for sessionID:) -> [Transcript.Entry]` through Router's
`TranscriptTree` reconstruction.

The ownership boundary: **`TranscriptStore` does not record and does not
restore.** It owns the root location policy, the project registry, and light
browse summaries. Router owns everything that gives a `transcript.jsonl` its
meaning: event writes, entry reconstruction, compaction checkpoints, and
live-session rebuild (`RoutedLLM.restoreSessionTree`). This package calls
Router for those.

The store persists three values for each session. `session/list` (§9) needs
them, and they are not derivable later: a generated **title** (from the first
user prompt, cut to a single line; a model-generated title is a follow-up),
**`updatedAt`** (kept in the record, not read with stat), and the session's
**complete ordered `additionalDirectories` list**. The list is an ordered
list, not a set. Each `session/resume` *replaces* it.

---

# Part II — The protocol surface

*One section for each ACP v2 spec page, in the spec's order. Each section
states the peer for that page's nouns. A noun with no peer is off, honestly.*

## 5. Initialization

**`info` is required.** `InitializeResponse` requires `protocolVersion` and
`info`. `Implementation` requires `name` and `version` (`title` is optional).
Report `name` as the programmatic identifier: the package/product name. Do not
use the dotfolder `<name>`. That name is the user's private selection. It has
no place on the wire. Report `title` as the display name. Report `version` as
the build version. Clients show these values.

**Version negotiation is behavior, not a number.** (`ProtocolVersion` is a
`uint16`.) The client sends the latest version that it supports. If we support
that version, we MUST send back the same integer. If not, we MUST send back
the latest version that we support. The *client* then decides to disconnect.
We are v2-only. Thus, concretely: **a client that sends `1` gets `2` back in a
normal, successful response. It does not get an error.** Log it. Answer
honestly. Let the client disconnect.

**What we advertise** (`capabilities`, `info` — the v2 names, not
`agentCapabilities`/`agentInfo`):

- `capabilities.session`, baseline `{}` at minimum, with:
  - `prompt` — the content types that the roster can consume (§12).
  - `mcp: {stdio: {}, http: {}}` (§11.5).
  - `delete: {}` — advertised. It is a real delete (§10.2).
  - `additionalDirectories: {}` — advertised. Confinement is multi-root
    (§7.2).
- **Capability markers are objects, not booleans, at each level.** `{}` means
  supported. Omitted or `null` means not supported. There is no `true`. (The
  `PromptCapabilities` members are `PromptImageCapabilities` /
  `PromptAudioCapabilities` / `PromptEmbeddedContextCapabilities`. The `mcp`
  members are `McpStdioCapabilities` / `McpHttpCapabilities`.)
- **We omit `capabilities.auth` and `authMethods`** (§6).

**Read the client's capabilities with this rule: absent means unsupported.**
This is the spec's own MUST. Stable v2's `ClientCapabilities` has only
`_meta`. Thus there is nothing to read today. The rule stays important: the
`_meta`-negotiated elicitation gate (§16) must default to unsupported when the
key is missing.

**Accept malformed capabilities.** The schema marks `capabilities` with
`x-deserialize-default-on-error` and `default: {}`. A capabilities object that
we cannot parse degrades to "supports nothing". It does not fail `initialize`.

**We apply the order rule.** Clients MUST initialize before they make a
session. A `session/*` call that comes first gets a JSON-RPC invalid-request
error. We do not serve it. If we did, we would act on capabilities that were
not negotiated.

## 6. Authentication

**There is none. A local on-device agent has no authentication surface.** Omit
`authMethods`. (The spec: agents without authentication needs simply omit it.)
This removes the obligation to supply `auth/login` and `auth/logout`. Clients
MUST NOT call them. We never raise the `auth_required` error (-32000). A
defective client that calls `auth/login` gets **`-32601`** ("the method does
not exist **or is not available**"). This is the correct code: the method
exists in the protocol, but not on this agent. Auth method descriptors key on
`methodId`, not `id`.

**"No ACP auth" is not "no credentials".** ACP authenticates the agent to the
client. We operate without that. MCP servers are a different axis, and they do
carry credentials: the `headers` of an `http` server (§11.5), from our config
or from the client. One rule keeps these facts compatible with committed
transcripts (§4.3): **do not persist client-supplied MCP server
configurations** (§7.3).

## 7. Session Setup (`session/new`, `session/resume`)

### 7.1 What a session is

One ACP session = one root Router session, with the same ULID (§4.2).
`session/new(cwd)` ⇒ the per-cwd config layer (§2.2) + the tool roster (§11)
+ the assembled instructions (§3) → `router.makeSession(...)`. `cwd` MUST be
absolute. It MUST be part of the session's effective root set. This is
load-bearing: `cwd` is where the transcripts go (§4.1).

**We support multiple concurrent ACP sessions from the start.** The
`sessionId` keys the sessions. Each session has its own cwd-derived config
layer, instructions, confinement, and transcript directory. Turns serialize at
the model's `serialGate`. Recording stays per-session at Router's chokepoint.
**Per-project profiles are possible now.** Router's pooled, reference-counted
residency (`kh01tv2`, landed; `PooledResidencyTests` covers it) gives one
memory-budget authority. It shares a model that two profiles both name. It
fails cleanly when a union does not fit the budget. Gate waits obey `Task`
cancellation. Thus a queued session's `session/cancel` does not wait for a
different session's turn.

**One prompt for each session at a time.** `idle` means "ready for a new
prompt". A `session/prompt` that comes while the session is not idle is a
client error, not a queue entry. The composer owns queueing. We intentionally
do not show Router's own prompt queue over ACP.

### 7.2 `additionalDirectories` — multi-root confinement

We advertise it and we apply it. **It is not a passthrough field.** If we
accept it but confine to cwd only, we refuse each tool call outside the
primary root. That is worse than no advertisement.

- `session/new` and `session/resume` carry `additionalDirectories:
  [AbsolutePath]`. Each path MUST be absolute. The array has
  `x-deserialize-skip-invalid-items`: skip and log a bad entry; do not refuse
  the session. **The list is ordered.** The order persists for each session
  (§4.6).
- **The roots extend confinement only. They do not change `cwd`.** `cwd` stays
  the base for relative paths. Each thing keyed on cwd stays **singular**: the
  config layer (§2.2), the AGENTS.md walk (§3.2), and the transcript directory
  (§4.1). A vendored dependency that you can read is not a project whose
  `AGENTS.md` governs you. A second root must never fork the transcript
  location. `PathGuard` gets the root set. `ShellPolicy` accepts the roots as
  valid working directories.
- **On resume, the list is authoritative and replaceable. It is not sticky.**
  A non-empty list is the complete resulting root set. Omitted or empty means
  **no** additional roots. Do not inherit the session's former roots. Rebuild
  confinement from the request contents, each time. This keeps a boundary that
  the client made narrow from silent re-widening.

Upstream: FileTool `939nnzx` (multi-root `PathGuard`) is the one blocking
dependency. It is in progress. Shelltool needs nothing. It is not
root-confined (§11.4).

### 7.3 `mcpServers` — the client's servers

`session/new` and `session/resume` both carry `mcpServers: [McpServer]`.
Client-supplied servers have session scope. We connect them **in addition to**
the config-derived servers, after them. (ACP's `name` is our
`ServerIdentity`.) **One decision is open, and we record it as open**: at a
name collision, can a client-supplied server *replace* a config-derived
server, or do we refuse the collision? State the rule before implementation.
Connection must complete **before** the tool array reaches
`makeSession(tools:)`. Router's tool-instancing pipeline is synchronous. Thus
we connect during the `session/new`/`session/resume` handling.

**Do not persist the client-supplied list.** `session/resume` carries
`mcpServers` itself. Thus the client is the source of truth at each reconnect.
There is no storage, no stale data, and no reconciliation. This is also
necessary: the `headers` of an `http` server carry bearer tokens, and §4.3
commits session metadata to a shared repo. Config-derived servers are the
user's own committed file and the user's own decision. `{{ env.TOKEN }}`
templating (§2.4) keeps the secret out of that file. This constrains our
`sessions.jsonl`. Router's `session.json` sidecar is already clean.

Shapes to keep in mind: `McpServerStdio` requires only `name` + `command`.
`McpServerHttp` requires only `name` + `url`. Thus `args`, `env`, and
`headers` are optional. They are not required-but-empty. `env` and `headers`
are **arrays of `{name, value}`, not maps**. Duplicate names are possible on
the wire. The last one wins.

### 7.4 Resume and replay

- **The client's `cwd` MUST be equal to the original.** Compare it with the
  cwd that Router recorded at creation. At a mismatch, give an error. Do not
  silently re-root confinement. (§9 confirms this from the other side:
  `SessionInfoUpdate` has no `cwd` field. Thus a session's cwd cannot
  change.)
- Restore assembles this package's side again (the config layer, the
  instructions, the confinement) from the recorded cwd. Router restores the
  session itself (Router board `6j4bven`).
- `replayFrom: {"type": "start"}` replays the history before the response
  returns. Omitted or `null` skips the replay. **Replay sends whole-message
  upserts** (`user_message` / `agent_message` / `agent_thought`) with the
  initial `messageId`s. It does not send the `*_chunk` variants of a live
  turn. The same ids let a client that saw some messages converge. It does not
  make duplicates.
- **`ReplayFrom` is an inclusive cursor.** `start` is only its first variant.
  Write the replay path with the cursor as the parameter. Do not hardcode
  replay-everything. A resume from a message id is the clear next variant.
- **Replay comes from Router's full recorded history** (the conversation that
  the user had). **The live session comes from the newest compaction
  checkpoint** (the model's work transcript). These are two different
  transcripts, intentionally.
- A resume of a deleted session fails naturally. The transcript is gone
  (§10.2).

**`configOptions` rides both responses.** `NewSessionResponse` and
`ResumeSessionResponse` each carry it. That is the list's primary announcement
(§15).

### 7.5 `session/fork`

**It is unstable-schema-only, but the peer exists**: Router already forks
sessions (§4.2). If the method graduates to stable, this is a cheap win, not
new machinery. Do not build it against the unstable schema.

## 8. Prompt Lifecycle

### 8.1 The turn: acknowledge, then notify

`session/prompt` returns `{}` **immediately** at acceptance. The turn comes as
notifications. **The order is important**: send the `{}` response *first*,
then `user_message`, then `state_update: running`, then the turn's output,
then `idle` + `stopReason`. The wire package supplies the primitive:
`AgentSideConnection.afterRespondingToCurrentRequest(_:)` delays work until
the `{}` went out. Use it. Do not use a detached task that races the response.

The handler dispatches slash commands (§14.3) before all of this. **The prompt
echo is a MUST**: "the Agent MUST report where the user message was inserted
in session history". That update is the source of truth for the agent-owned
`messageId`. A `user_message_chunk` stream also satisfies the rule.

### 8.2 The state machine

`state_update` carries `running` / `idle` / `requires_action`. The conformance
needs a named owner for this state machine:

- `running` at turn start.
- **`requires_action` each time we stop on the human**: around
  `session/request_permission`, and around each elicitation round-trip (§16).
  Pair it with Router's `awaitingUser { }`. Then the per-model generation gate
  opens at the same moment that the protocol says "blocked on user". Go back
  to `running` at the answer. (`requires_action` is "foreground work is
  blocked on user action". Permission is only the frequent case.) A turn that
  stays in `running` while it waits on a person shows as a stopped agent. And
  Router keeps the gate through the full turn. Thus a naive wait blocks each
  other session and fork on that model.
- `idle` with a `stopReason` at turn end. Background work can continue during
  `idle`. Its notifications do not change the state.

**The `StopReason` mapping**: completed → `end_turn`; guardrail refusal →
`refusal`; cancel → `cancelled`; budget end → `max_tokens`; tool-loop cap →
`max_turn_requests`. The value is `_`-extensible. **Catch the cancellation
exception and map it.** A Swift `CancellationError` that gets out as a
JSON-RPC error, or as `refusal`, is the failure that the spec names.

### 8.3 The upsert algebra

The replay decision stands on this. The agent-generated
**`messageId`** keys the messages. v2: "the Agent owns session history, so it
is the single source of message identity". That is our invariant ("the
FoundationModels `Transcript` is the record") as the protocol's own position.

| Update | Effect on the message with that `messageId` |
|---|---|
| whole-message, `content` omitted | content unchanged (other fields may update) |
| whole-message, `content: null` or `[]` | cleared |
| whole-message, `content: [X]` | **replaces everything accumulated**, chunks included |
| `*_chunk` | appends |
| any update with a new `messageId` | a new message begins |

The third row is load-bearing. It is why replay-as-upserts converges a client
that saw the chunk stream (§7.4). `ContentChunk` requires
`messageId` **and** `content`. The whole-message forms require only
`messageId`.

### 8.4 The `session/update` stream — Router's events on the wire

| Router `SessionEvent` | ACP `SessionUpdate` (v2 discriminator) |
|---|---|
| `textDelta` | `agent_message_chunk` (with the agent-generated `messageId`) |
| `reasoningDelta` | `agent_thought_chunk` |
| `toolCall(id:name:argumentsJSON:)` | `tool_call_update` — v2 has no `tool_call` create variant; the first update carrying an unseen `toolCallId` *is* the creation, and SHOULD carry `title` |
| `toolStatus(id:status:summary:)` | `tool_call_update` (`running` → `in_progress`) |
| `compaction(CompactionResult)` | `usage_update` — the context meter drops; no message change (§8.5) |
| `turnEnded(TokenUsage)` | `usage_update` |
| turn start / turn end | `state_update` — `running`, then `idle(stopReason)` |

The v2 discriminators are **`snake_case`** (`agent_message_chunk`,
`tool_call_update`, `in_progress`). The JSON *properties* are `camelCase`.
This is an easy place for a wire error.

- **`usage_update` is the context meter, and it is native**: `{used, size,
  cost?}` maps directly to Router's token meter and resolved context.
- **`session_info_update`** carries title/metadata changes in a session.
  Example: the moment when the first prompt gives a title (§4.6).
- ACP's `ToolCallStatus` is `pending` / `in_progress` / `completed` / `failed`
  / `cancelled`. `pending` (a queued call) and `cancelled` are additions to
  Router's vocabulary. A detached MCP call stays `in_progress` across turns.

**Decision: the terminal status comes from `OperationEvent.outcome`, through
one total function `OperationOutcome → ToolCallStatus`.** OperationTool card
`1ad4ydw` puts a shared terminal-outcome vocabulary — `succeeded` / `failed` /
`timed_out` / `stopped` / `cancelled` / `lost` — on the `OperationEvent`
envelope, and Shelltool (`jt19xwc`) and FoundationModelsMCP (`zfp4a3j`) emit
it (§21). We write the function once, for every event-posting tool. We do not
parse per-tool `detail` payloads to decide status. The mapping:

| `OperationOutcome` | ACP `ToolCallStatus` | Text |
|---|---|---|
| `succeeded` | `completed` | — |
| `failed` | `failed` | the tool's error |
| `timed_out` | `failed` | names the timeout ("timed out after Ns") |
| `stopped` | `cancelled` | authoritative — the work was killed |
| `cancelled` | `cancelled` | advisory — "we stopped listening" (§8.6) |
| `lost` | **`_lost`** | "we do not know if this ran" |
| unknown / other | the raw value under the `_` rule (§18) | generic rendering |

- **`timed_out` maps to `failed`, not `cancelled`.** Nobody asked for the
  stop, and the caller must treat the result as an error. The text names the
  timeout, so the failure is explicable.
- **`lost` never flattens into `failed`** (the existing decision, unchanged).
  The extensible status **`_lost`** rides with "we do not know if this ran"
  in the text, for clients that ignore custom values.
- An outcome value this function does not know keeps its raw value under the
  `_` extension rule (§18), with a generic rendering. The function is total:
  a new upstream outcome degrades the display, never the stream.

### 8.5 Compaction on the wire

**Verified in Router (2026-07-29): compaction does not rewrite the durable
history.** The record is an append-only journal. Compaction appends a
`CompactionSegment` checkpoint through the same recorder chokepoint
(`diffAndRecordCompaction` → `recorder.append`). Router's reconstruction doc
states it plainly: "compaction only ever appends (nothing before it is ever
touched or removed)". Reconstruction gives two views over the one journal:
`.fullHistory` (every entry; the checkpoint shows among them as a fold marker)
and `.restore` (the newest checkpoint plus the entries after it — the model's
working transcript). Only the model's in-memory working set is non-monotonic.

**Decision: the wire keeps the same shape — compaction changes no
user-visible message.** We send no upserts that clear or rewrite folded
messages. The session history that a client shows is the full conversation,
and it only grows. What compaction emits:

- **`usage_update`** with the new `used` size. The visible effect is that the
  context meter drops.
- Nothing else. The fold summary is model-context material. It stays in the
  journal as the checkpoint, reachable through the transcript (§19.1). It is
  not a chat message.

Replay (§7.4) is consistent for free: it replays the full history, and
checkpoint entries are not messages, so replay does not emit them. This also
removes the old upstream ask on Router (`CompactionResult` message identity):
we never need to know which messages a fold touched, because we never touch
them on the wire.

### 8.6 Cancellation (`session/cancel`)

It is a notification with a defined confirmation. Answer each pending
`session/request_permission` with the **cancelled** result. Stop the work.
Then send `state_update` `idle` with `stopReason: "cancelled"`. Agents MAY
send updates after `session/cancel`, but MUST send them *before* the idle
update. `idle` + `cancelled` is strictly the terminator. The client has its
own half: it marks unfinished tool calls as cancelled, and it answers pending
permissions. We still send correct terminal tool statuses. But we do not hold
the `idle` for that.

**The chain has a known gap.** Router's cancellation is queue-side. A turn
that went to the model runs to completion. The chain from `session/cancel` to
an in-flight MCP call needs Router's in-flight cancellation first (open,
upstream). And MCP's `notifications/cancelled` is advisory. Thus the honest UI
result is "we stopped listening", not "it stopped".

## 9. Session List (`session/list`)

`TranscriptStore.sessions(inProject:)` (§4.6) supplies this. With
project-local storage, the usual `cwd`-filtered query is one directory read.
The unfiltered cross-project list goes through `projects.jsonl` (§4.5). A
filter with an unknown directory returns an **empty array, not an error**. The
method is baseline. It is not capability-gated.

**`SessionInfo`**: `sessionId` and `cwd` (absolute) are required. `title`,
`updatedAt`, and `additionalDirectories` are optional in the schema. We make
and persist a title anyway (a product decision, not conformance — §4.6). We
keep `updatedAt` (RFC 3339) current. We report `additionalDirectories` as the
complete ordered list from the most recent activation.

**Immutability**: `SessionInfoUpdate` carries only `title` and `updatedAt`
(each nullable, to clear). There is no mechanism to change `cwd` or the root
list. This confirms the resume `cwd` check (§7.4). There is also no push for a
root-list change. A connected client learns a new root set only at its next
`session/list`. That is a protocol gap. Do not synthesize an update for it.

**The order and the pagination are ours to define, and they must agree.** Sort
by **`updatedAt` descending, with `sessionId` as the tiebreak**. `session/list`
has cursor pagination. The request params are `cwd` (a filter) and `cursor`.
The response carries `nextCursor`. The tokens are opaque (clients MUST NOT
parse or persist them). The page size has a limit. An invalid cursor gives an
error. **The cursor encodes the sort key, not an offset.** Thus pagination
stays correct through concurrent writes. There are no duplicates and no skips.

**What is listable** (the spec does not say):

| Session state | Listed? | Why |
|---|---|---|
| active | yes | — |
| closed | **yes** | closing frees resources but retains the transcript; resuming it is the point |
| deleted | no | delete removes it from history by definition |
| created, zero turns | **no** | nothing to resume; noise in every picker |

The zero-turn rule is free. We write a session directory when there is data to
record. Thus "has a persisted transcript" *is* the listability test. Roots
only: `parentId == nil && agentSpawn == nil` (§4.2). Forks and sub-agents do
not show as conversations.

## 10. Session Management (`session/close`, `session/delete`)

### 10.1 `session/close`

This is a **MUST**: cancel the session's work "as if `session/cancel` had been
called", then release the resources. That includes cancellation's full
semantics (§8.6). Pending permission requests get the cancelled result. A
close during an active turn **sends `state_update` `idle` with
`stopReason: "cancelled"` before the close response**. If not, a client with a
spinner does not learn that the turn ended. Then release: in-flight MCP calls,
detached work, spawned stdio server processes (§11.5), **and the session's
descendants**. A fork or sub-agent that operates is this session's work. If it
continues after close, it burns a model gate with no watcher. That is the
failure that this MUST prevents. Recording closes. The transcript **stays** on
disk.

### 10.2 `session/delete`

**It is capability-gated. We advertise it. It is a real delete, not a
tombstone.** Remove `<cwd>/.<name>/transcripts/<sessionId>/` and its
`sessions.jsonl` entry. The spec lets us select soft or hard. A user who asks
for a delete means "gone". **Version control makes that safe.** `git rm` is a
normal operation because the history keeps what it removes. The git history is
the recovery path. It is not a reason to keep the file in the working tree.

- To delete an active session: close it first (§10.1 semantics, descendants
  included). Then delete it.
- A resume of a deleted session fails. The transcript is gone. The absence
  does the work.
- Already-deleted and never-existent both succeed silently. "Nothing to
  remove" is not an error. A directory removal gives this naturally.
- **Honesty**: the delete removes the working-tree and index copy. Data that
  was committed stays in the git history. The ACP response and the docs must
  not say that the content is not recoverable.

## 11. Tool Calls

*This is the tools' home. v2 removed `fs/read_text_file`,
`fs/write_text_file`, and all five `terminal/*` client methods. It points
agents to their own file access, their own execution, and MCP. Thus the
built-in roster below is the **full surface** through which this agent touches
the user's world. In-process tools are the approved design, not an accepted
risk. The confinement story stays ours: `PathGuard` bounds `files`. The
composed `ShellPolicy` bounds `shell`. `session/request_permission` asks the
user before either goes further.*

### 11.1 The catalog

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the one place
where we register tools. Each linked package gets one reserved config section.
To add a tool: add a dependency, and add one catalog line:

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

`ToolContext` carries what each constructor needs: the session working
directory, the session's additional roots, and the decoded config section.
Frontends can append their own tools. `makeSession(tools:)` receives the
merged array. Catalog entries also register slash-command providers (§14.2).
An entry can pair its tool with a `SlashCommandProviding` conformer. The
catalog feeds it into the session's command registry. The direction rule is
absolute: tool packages conform to the leaf's protocol. No code outside this
package names this package's types.

### 11.2 The enable/disable rule

**Each built-in is on, unless the config sets it off. Absence enables.** A
user with no config file gets an agent with all tools, each with its own
defaults. One rule, five shapes:

| Config | Meaning |
|---|---|
| no `tools:` section | every built-in on, with defaults |
| `tools:` present, tool not mentioned | that tool on, with defaults |
| `shell: {}` / `shell:` (null) / `shell: true` | on, with defaults — explicit but redundant |
| `shell: {policy: strict}` | on, body decoded as **that package's own option type** |
| **`shell: false`** | **off** — not constructed, never reaches the model |

`false` is intentionally *outside* the body. The body is the tool package's
own option type. An unknown key in it is an error (§2.4). An `enabled:` key
would force each package to carry a flag that only this layer wants. The codec
first checks for a scalar `false`. Then it decodes the mapping.

- Disabling is per-tool, one at a time. There is no `tools: false` switch and
  no `only:` allowlist. A config that silently removed the full roster would
  be too easy to write by accident.
- Layering is §2's usual key-level override. The nearest layer that names the
  tool wins. Thus a user layer can disable, and a project layer can enable
  again.
- **A new built-in arrives enabled** for each user, at upgrade. That is the
  intended batteries-included behavior. But then a new roster entry is a
  user-visible capability change. Release it as one.

**`mcp:` is the one entry whose body is a list** (servers, not options):

- **omitted**: MCP is on, with no configured servers. The client's per-session
  `mcpServers` (§7.3) still connect. This is the correct default: an editor
  with its own servers operates against a stock config.
- **`mcp: [ … ]`**: those servers, plus the client's.
- **`mcp: false`**: MCP is fully off. **We also refuse client-supplied
  servers.** This is an intentional security position ("this agent speaks with
  nothing that I did not link"). It is different from `mcp: []`. Log the
  refusal. A client whose servers disappear without explanation is the worst
  version of this.

### 11.3 The roster

**Built in, day one — declared dependencies, in the default roster:**

| Tool | Source package | Blocked on | Config section |
|---|---|---|---|
| `files` | `FoundationModelsFileTool` (**built**) | nothing | `files:` |
| `shell` | `FoundationModelsShelltool` (**built**) | nothing | `shell:` |
| MCP servers | `FoundationModelsMCP` (**built**) — `MCPToolProvider` | nothing; the ACP tunnel is unstable-gated (§11.5) | `mcp:` (plus ACP's per-session `mcpServers`) |
| skills → `/id` commands | `FoundationModelsSkills` (**plan-only**) — the command-provider half | Skills M1–M3 + M5; Extras only (shipped) | `skills:` |
| skills → `search`/`list`/`use` tool | `FoundationModelsSkills` (**plan-only**) — the model-facing half | Skills M4 → `FoundationModelsOperations` 2/4/5 **and** `FoundationModelsMetadataRegistry` M1–M4, neither built | `skills:` |

**Follow-ups — one catalog line each, as each package ships:**

| Tool | Source | Blocked on | Config section |
|---|---|---|---|
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | thin `Tool` shim over `CodeContext` | nothing; first follow-up | `codeContext:` |
| `runCode` | `MultiTool` (JS composition over the catalog) | nothing | `multitool:` |
| sub-agents | FoundationModelsAgents | that package (plan-only) | `agents:` |

**Skills is a tool and a command provider. The two halves answer different
questions.** The tool is *discovery* ("what can I do here?", for the model).
The `/id` commands are *explicit dispatch* ("do this specific thing", for the
user). Day one ships **explicit dispatch without discovery**. The command half
depends only on shipped Extras. The tool half's dependency chain does not
exist yet. Until it lands, the model cannot see skills at all. That is a real
difference from `files`/`shell`. We decide it. We do not inherit it from a
dependency chain. (The two integration gaps: §14.2.)

### 11.4 Confinement

- **`files`**: `PathGuard` confines it to a **root set**: the session cwd plus
  its `additionalDirectories` (§7.2). `cwd` stays the special member (the base
  for relative paths). But a path in any root validates.
- **`shell`**: the composed `ShellPolicy` (§2.5) gates it. The policy has three
  results (`.allow` / `.ask(reason)` / `.deny(message)`). A
  `ShellDecisionStore` sits behind `remember(...)`. The `allow_always` /
  `reject_always` options of `session/request_permission` bind to it, when the
  permission mode asks (§11.7).
  **The shell is not root-confined. `additionalDirectories` does not change
  that.** `ShellContext` has no workspace root. `check(workingDirectory:)`
  validates only `..` traversal and existence. Confinement for `shell` is
  command-and-environment pattern rules, not a filesystem boundary. The blast
  radius of a shell command has a policy limit. A wider workspace does not
  widen it. (A different open question: must `shell` *also* be root-confined?)
- **`mcp`**: dynamic. The tools that it gives depend on what the servers
  advertise. Connection completes before the array reaches
  `makeSession(tools:)` (§7.3).

### 11.5 MCP wiring: two sources, two transports (+ one unstable), two sinks

**Sources**: the local `mcp:` config, and the client's per-session
`mcpServers`. Compose them per §7.3 (client servers have session scope, come
after config-derived servers, and never persist).

**Transports** (advertise them as `McpCapabilities` at `initialize`,
`capabilities.session.mcp`; nothing does that today):

- **stdio** → `StdioServerProcess`. The `McpServerStdio` fields map one to
  one. `capabilities.session.mcp.stdio`.
- **http** → `HTTPClientTransport`. ACP's `headers` supply the auth.
  (Authorization stays the host's job, per `FoundationModelsMCP`'s decision.)
  `capabilities.session.mcp.http`.
- v2 removed `sse` fully. There is no `McpServerSse`, and no third stable
  transport.

**The ACP tunnel is unstable-schema-only. Plan it. Gate it. Do not promise
it.** `mcp/connect` + `mcp/message` + `mcp/disconnect` exist only in
`acp-v2.meta.unstable.json`. No stable capability can ask for a tunnel. The
design, when it lands: the **client** hosts the server. The agent tunnels MCP
JSON-RPC over ACP. **`ACPTunnelTransport` goes in this package.** It is an
`MCP.Transport` conformance that needs ACP types. `FoundationModelsMCP` must
never depend on `FoundationModelsACP`. The transport plugs into that package's
transport factory. The client owns the processes. Thus `StdioServerProcess` is
not used. Two blocks exist: the wire package must generate the `mcp/*` payload
types (filed as `kdvsjmj` on its board), and the methods must graduate to
stable. Ship stdio + http first.

**Process lifecycle is FoundationModelsMCP's job, not ours.** It spawns and
owns the stdio subprocesses. Reconnects and cross-session pooling are upstream
asks on that package. This package passes entries to `MCPToolProvider` and
receives `[any Tool]`.

**Two sinks receive one tool call.** A long MCP call reports to two audiences:

- **model-visible**: `OperationEvent` → Router's `SessionOutbox` → the
  transcript.
- **user-visible**: `tool_call_update` with `toolCallId`, `status`, `content`,
  `kind`, `locations`, `rawInput`, `rawOutput`.

The MCP call handle is the `OperationEvent.correlationID`, the ACP
`toolCallId`, and the id that scopes an elicitation (§16). A detached MCP call
is why `status` stays `in_progress` across turns. The mapping decisions:

- **The terminal status comes from `OperationEvent.outcome`**, through the
  one total `OperationOutcome → ToolCallStatus` function of §8.4. The
  function is written once, for every event-posting tool. No per-tool
  `detail` parsing decides status. A lost MCP connection is `outcome: lost`
  and rides as **`_lost`** (an extensible status, §18). Do not flatten it
  into `failed`. Add "we do not know if this ran" in the text.
- `rawInput` / `rawOutput` / `content` / `locations` need the **structured
  per-call record** from `FoundationModelsMCP`. They do not use its
  model-facing rendered string. That string is elided, intentionally.
- **`ToolAnnotations` → `ToolKind`**: the correct use of MCP's untrusted
  hints. A UI hint feeds a UI hint. It is never a gate.
- **`destructiveHint` / `openWorldHint` → `session/request_permission`**: here
  "hosts may gate on annotations" becomes real. The bridge never gates. This
  package gates only in the `policy` and `ask` modes; the default `"*"` mode
  never asks (§11.7).

The shared-outcome decision changes terminal status only. The
`ToolAnnotations`-driven decisions above — `ToolKind`, permission gating —
are untouched.

### 11.6 Reporting: `tool_call_update`

v2 has no `tool_call` create. `tool_call_update` is an upsert. The first
update with a new `toolCallId` is the creation.

- **`status` defaults to `pending`** when a creating update omits it. A call
  that already runs must say `in_progress`. If not, the client shows it as
  queued.
- `ToolCallUpdate` requires only `toolCallId`. `title` SHOULD be on the first
  report.
- **The diff mapping trap**: ACP's `path` is absolute and **post-operation**.
  For `move` / `copy` (`DiffPathPairChange {oldPath, path}`), FileTool models
  the same data in the other direction. Map `FileChange.path → oldPath` and
  `FileChange.destinationPath → path`, for those two kinds only. For `add` /
  `delete` / `modify`, map `path → path` without change. A naive
  `path → path` map shows the pre-rename filename at each move, silently.
  (FileTool's shape is self-consistent. This is a translation note, not an
  upstream ask; `d7jwam5`.)
- `DiffChange` carries optional `fileType` / `mimeType`. Fill them where the
  tool knows them. They drive syntax highlighting in the client.
  `ToolCallLocation` requires `path`. `line` is optional (`GrepMatch` supplies
  both).
- `status`, `kind`, `title`, `rawInput`, and `rawOutput` all have
  `x-deserialize-default-on-error`. A bad field degrades. It does not fail the
  notification.

### 11.7 `session/request_permission`

**The permission mode: allow by default.** Approval prompts cost the user
time on every tool call. The default is trust: a stock agent never sends
`session/request_permission`. Asking is an opt-in for the careful, not a toll
on everyone. The `permissions:` config section (§2.4) controls it:

| Config | Meaning |
|---|---|
| absent, or `permissions: "*"` | **the default** — never ask; every tool call that confinement and the deny floor permit runs |
| `permissions: policy` | defer to each tool's own signals: shell's `.ask` rules, MCP's `destructiveHint` / `openWorldHint` |
| `permissions: ask` | ask before every tool call |
| mapping form — `permissions: {shell: policy, mcp: ask}` | one mode per tool; an unmentioned tool uses `"*"` |

Two rules bound the mode:

- **`"*"` does not touch the deny floor.** Denials (§2.5) refuse, with a
  message, and without a prompt. Allow-everything means "do not ask". It does
  not mean "permit what is denied".
- **A layer can only make the mode stricter.** The order is `"*"` → `policy`
  → `ask`. A project layer can move a tool up this order, never down. If it
  could, a cloned repo would silently switch off the prompts that a careful
  user opted into — the same shape as §2.5's denial union.

Under `"*"`, shell's `.ask(reason)` outcomes resolve as allow, and MCP's
hints never gate. Under `policy`, each signal does what it says. Under `ask`,
every call asks. The wire shape below applies whenever the mode does ask.

The shape: `{sessionId, title, options[≥1], description?, subject?}`. The
prompt copy (`title`/`description`) is separate from the structured `subject`.

- **`subject: tool_call` carries a full `ToolCallUpdate`, not a
  `toolCallId`.** The request itself gives the title, the kind, `rawInput`,
  and the locations. The design result: **ask before you send a
  `tool_call_update` for that call.** Then no "pending" call sits in the
  timeline for a thing that the user can refuse. Ask first. Send at approval.
- `subject: command` is `{command, cwd}`, required, plus optional `toolCallId`
  and `terminalId`.
- `PermissionOption` requires all three of `optionId`, `name`, `kind`.
  `PermissionOptionKind` includes `allow_always` / `reject_always`. Thus
  **this package persists the always-decisions**. They bind to Shelltool's
  `ShellDecisionStore`, with `.session` as the default scope (§2.5).
- The result is `cancelled` or `selected(optionId)`, plus an `other` extension
  variant. **Handle an unknown result as a refusal.** Never handle it as an
  approval.

### 11.8 Agent-owned display terminals

The spec documents terminals under Tool Calls. The vendored schema has them.
They are **display-only**. This is not the removed `terminal/*`
client-execution surface again. We execute. The client renders. The schema:

| Schema type | What it is |
|---|---|
| `TerminalId` | unique id for an agent-owned terminal within a session |
| `Terminal` (a `ToolCallContent` variant) | display-only reference — `{terminalId}`; state and output arrive separately |
| `TerminalUpdate` (`session/update`) | upsert of terminal state; only `terminalId` required, other fields patch |
| `TerminalOutputChunk` (`session/update`) | appended bytes, independently base64-encoded |
| `TerminalOutput` | authoritative replacement snapshot of output bytes |
| `TerminalExitStatus` | `{exitCode?, signal?}`; its presence marks exited, even with neither known |

The mapping is `shell`'s user-visible payoff. Shelltool's `commandID` →
`terminalId`. Incremental line streaming → `terminal_output_chunk` (base64 for
each chunk; byte-true, with no lossy text coercion). The stored record →
`TerminalOutput` (what a reconnecting client needs). Command exit →
`TerminalUpdate.exitStatus` (the "exited even when unknown" semantics agree
with a soft-deadline kill). The tool call sends a `Terminal` content
reference. The bytes ride the terminal stream.

**Sequence**: the stream is additive over the usual tool-call content. Thus
`shell` ships text-in-`content` first. The terminal stream is a follow-up. But
do not design the shell tool's output path so that it discards raw bytes
before the wire.

## 12. Content

**ACP's `ContentBlock` *is* MCP's.** The spec says this directly. Thus the map
from an MCP tool result's content to `tool_call_update.content` keeps the
shape. There is no semantic loss. (Two Swift types in two packages, thus not
zero code, but nothing to decide.)

**The prompt capabilities are honest** (§5). Text is the one unconditional
MUST. We advertise `image` / `audio` / `embeddedContext` only when the roster
can act on them. An absent capability is better than an image that we accept
and drop.

**`resource_link` is not capability-gated.** It can arrive at all times
(required `name` + `uri`; optional `mimeType`, `size`, `title`, `description`,
`icons`). **The decision: resolve `file://` URIs inside the session's root set
through the `files` tool. Refuse each other scheme and each out-of-bounds
path, with a reason.** A silent fetch of an `http://` URI from a prompt is a
request that the user did not make, from a process that holds the user's
credentials. `PathGuard` refuses `file://` outside the root set, as it refuses
each other out-of-bounds path.

Field details, so that no one must find them again: `TextContent` requires
`text`. `ImageContent` / `AudioContent` require `data` + `mimeType` (image
also permits an optional `uri`; audio does not). `EmbeddedResource` requires
`resource`: `TextResourceContents` (`text` + `uri`) or `BlobResourceContents`
(`blob` + `uri`). `Annotations` carries `audience`, `priority`,
`lastModified`. It is safe to ignore on input. Fill it on output where we know
the answer.

## 13. Agent Plan

**It has no peer. It is off, and we say so.** Router has no planning noun. v2
says only that agents SHOULD report plans. We send nothing, and we say so.

For the time when a planner lands (FoundationModelsAgents), know this
asymmetry: **`plan_update` is the one v2 update that replaces. It does not
patch.** Agents MUST send the complete entry list. Clients MUST replace the
previous contents fully. An implementer who knows the upsert algebra (§8.3)
will do this in reverse. `PlanEntry` requires all three of `content`,
`priority` (`high`/`medium`/`low`), and `status`
(`pending`/`in_progress`/`completed`/`cancelled`). Each is `_`-extensible.
Multiple concurrent plans are possible. `planId` divides them. Each variant
MUST carry it.

## 14. Slash Commands

*This is the commands' home. Slash commands are a session-level noun.
`/compact` acts on this session. A skill from this repo becomes a command in
this session only. There is one registry for each session. We assemble it at
session creation, as we assemble tools and instructions. We publish it again
when a source changes.*

**Extras' `SlashCommand` is the cross-package vocabulary**: `name` /
`description` / `argumentHint`, plus a two-kind `Body`. `.prompt(template:)`
expands into a usual model turn. `.action` runs code and streams text. It does
not touch the model. Contributors implement `SlashCommandProviding`
(`commands(workingDirectory:)` + an optional `commandUpdates` stream) against
the leaf, never against this package. The registry mechanics are this
package's: merge, precedence, near-miss matching, and `commandUpdates`
re-publication.

### 14.1 Three sources, merged in precedence order

The later source wins at a name collision (logged). Builtin names are
reserved. Nothing replaces them.

1. **Builtins**: this package's `.action` closures that capture the session.
   `/compact` (do compaction now), `/context` (fill, tokens, resolved context;
   we keep it for CLI ergonomics; the app binds `usage_update` in place of it,
   §8.4), `/memory` (print the assembled instructions with source headers),
   `/status` (session id, cwd, model/profile, transcript path), `/config`
   (print the applicable configuration as YAML with comments;
   `/config export home|project` writes it to that layer), `/help`. Frontend
   verbs (`/quit`, clear-as-new) stay out. They are composer functions, with
   the same rule as queueing.
2. **Linked providers**: `SlashCommandProviding` conformers from catalog
   roster entries (§11.1). This is the *code-backed* lane. Only linked Swift
   can construct `.action`. That is the trust boundary. In-process code is
   already trusted as tools.
3. **Skills**: the *data* lane. `FoundationModelsSkills` finds and renders
   `SKILL.md` files. `SlashCommandProviding` surfaces them. One skill = one
   `/id` command. `commandUpdates` pushes changes when files change. Skill
   markdown is **data**. It can only make a prompt. A broken or hostile
   `SKILL.md` makes, at worst, a bad prompt under the usual tool confinement.
   It can never become `.action`.

(MCP prompts are the reserved further source. `prompts/list` + `listChanged`
will feed this same registry when we wire it.)

### 14.2 Where skills live, and the two integration gaps

**Skills resolve through `DotfolderStack(name: "skills")`**:
`$XDG_CONFIG_HOME/skills/` (default `~/.config/skills/`) and `<cwd>/.skills/`.
Two layers. The nearest wins, by directory name. `skills` is only the `<name>`
of a second stack. There is no new mechanism. The XDG rule is the same.

- **The name is a constant, not our `<name>`. That is the point.**
  [agentskills.io](https://agentskills.io) is an ecosystem format. A skill is
  a property of the user and the repo. It is not a property of the agent that
  reads it. **`<name>` isolation does not apply to skills.** Two agents on
  this stack, with different dotfolder names, share one skill library. That is
  the intent. We put it on the record because §2.1 makes a point of name-based
  isolation. (Precedent: the project-level `AGENTS.md` also has no qualifier,
  §3.2.)
- **We construct the stack. Skills takes what it gets** (§2.5).
  `FoundationModelsSkills` accepts its layer roots as a construction parameter
  (ordered, lowest first). It names no dotfolder convention. A host that wants
  a different layout passes different roots.
- **Trust**: both layers are untrusted. Skill markdown renders under the
  untrusted template rules.
- **The `skills:` config section stays in the `<name>` stack.** The content is
  shared. The behavior is per-agent. `skills: false` stops discovery for this
  agent. It does not touch a different person's library.

**Gap 1: Extras' `SlashCommand.Body` needs a third case.** Skills matches
neither current kind. It is not `.prompt(template:)`: Skills renders with its
own pipeline and argument model. If we give the raw body to Extras' Stencil
engine, the substitution obeys the wrong rules, silently. It is not `.action`:
that kind does not touch the model, but a skill's rendered body *becomes* the
turn. The necessary case:
`case rendered(@Sendable (Invocation) async throws -> String)`. The conformer
renders. The dispatcher gives the result to the model, as it does for
`.prompt`. Filed on Extras as **`c2pad49`**. The trust boundary stays: only
linked Swift can construct a closure. **This is wanted, not blocking.** The
workaround: dispatch skill commands through `registry.call(id:arguments:)`
directly, as a special case in our dispatcher. Use it if `c2pad49` is slow.
Prefer the case.

**Gap 2: ACP flattens the parameter model.** Skills has a real model
(`SkillParameter { name, position, required, variadic, placeholder }` +
`acceptsTrailingArguments`). ACP's `AvailableCommandInput` is a single
`{type: "text", hint: String}`. **Pass Skills' `argument-hint:` string
through, verbatim, as the hint.** It is already in display syntax
(`<env> [region] [flags...]`). Thus the lossy step loses nothing that a human
reader needs. Structured parameter prompting is an `_meta` extension, if a
client wants it.

**The phases obey §11.3's roster**: ship the command-provider half first. The
model-facing tool half comes after its dependency chain. A plan that handles
"skills as a built-in" as one indivisible item will stall.

### 14.3 Dispatch — at the prompt owner

**The spec confirms that this is the only possible dispatch point.** Commands
arrive as usual prompt text with a leading slash. There is no separate invoke
method. The prompt owners are this package's `prompt()` handler for the wire,
and the frontends' composers for direct consumption. Router's sessions know
nothing of commands. A `/compact` typed in an editor must never reach the
model as a prompt.

A leading `/name` goes through the registry *before* anything touches the
session:

- **`.prompt` (and skill) commands** expand (template + arguments) into a
  usual, recorded model turn.
- **`.action` commands** stream output. There is no model turn. There are no
  transcript entries other than what the action records (`/compact` its
  `CompactionSegment`; `/help` nothing).
- **An unknown `/name`** gives an error with near matches. It is never a model
  turn. Frontends escape a literal leading slash.
- **A command can arrive with other content attached.** (The spec permits
  `[text("/deploy prod"), resource_link(...), image(...)]`.) `.prompt` and
  skill commands carry the extra blocks **into the expanded turn**. If we drop
  them, we discard the file that the user attached. `.action` commands make no
  model turn. Thus the attachments have no place to go: **refuse the
  invocation, with a reason.** Silence is the one handling that is certainly
  wrong.

### 14.4 The ACP surface

At each registry change (a new skill, an edited template), the per-session
command set publishes again: CLI autocomplete, app palette. The conformance
sends **`available_commands_update`**. To advertise is a MAY. The list can
change at any time in a session. `commandUpdates` feeds it. `AvailableCommand`
requires `name` + `description`. `input` is optional. The text variant
requires `hint` (the argument hint goes there, §14.2). Custom input types MUST
start with `_`.

## 15. Session Config Options

v2 replaced session modes with typed config options, in the categories `mode`
/ `model` / `model_config` / `thought_level` (`session/set_config_option`,
`config_option_update`; `session/set_mode` and `current_mode_update` are
gone). Thus model selection, which is Router's full job, gets a
protocol-native surface.

**Day one ships one real option, not an empty array**: a `select`, category
`model`, over the `standard` / `flash` slots of the resident profile. Both
slots are already resident. Thus a switch loads nothing and blocks on nothing.
It specifically does **not** need pooled residency (`kh01tv2`). That is
necessary only for a *profile* switch. Say in the option's `description` that
this selects among the profile's slots. Then a user does not expect the full
candidate list.

What we intentionally do not give (each decided in a different section):
`model_config` context size (it comes from the model, §2.4), `mode` (no modes
exist here), `thought_level` (Router shows no reasoning-level knob). A thing
with no peer stays absent.

**`currentValue` must show the true state. Thus `config_option_update` is
load-bearing.** Router's joint-fit really selects among candidates by what
fits the host budget. When resolution lands on a different model than the
option shows, push the update. If not, the client's selector claims a model
that the agent does not run.

Schema details:

- The `session/new` / `session/resume` responses are the **first announcement
  of the list** (§7.4). The order is by priority. Thus the selector must be
  constructible at session creation.
- **The array order is significant.** It is a priority list, not a set.
- **`set` and the push each carry the complete state**
  (`required: ["configOptions"]`). It is the full set each time, never a
  delta.
- `SessionConfigOption` requires only `configId` + `name`. The `select` /
  `boolean` / `other` variants supply `currentValue` (and `options`). Grouping
  is a wrapper (`SessionConfigSelectGroup{groupId, name, options}`), not a
  field on options. We ship without groups. `category` is UX-only ("MUST NOT
  be required for correctness").
- **Each option MUST have a default.** Then a client that ignores config
  options gets a session that operates.

## 16. Elicitation

**This package owns elicitation.** It is the only layer with a live two-way
channel to a thing that has a user. `FoundationModelsMCP` defines the
`ElicitationCoordinator` protocol and owns no UI. Router owns no user channel
(`SessionOutbox` is one-way, outbound). Thus the coordinator lives here:
**`ACPElicitationCoordinator`**, which holds the `AgentSideConnection`.

**It is a relay, not a translation.** MCP and ACP elicitation are almost
isomorphic:

| MCP (swift-sdk) | ACP (`elicitation/*` — unstable schema) |
|---|---|
| `CreateElicitation` `.form(FormParameters{message, mode?, requestedSchema})` | `elicitation/create`, `mode: "form"`, `message`, `requestedSchema` |
| `.url(URLParameters{message, mode, url, elicitationId})` | `mode: "url"`, `message`, `url`, `elicitationId` |
| `Result.Action { accept, decline, cancel }` | `action: accept \| decline \| cancel` (+ optional `content`) |
| `notifications/elicitation/complete { elicitationId }` | `elicitation/complete { elicitationId }` (agent → client) |

The two directions of MCP elicitation both go through the one coordinator: a
server that stops in a tool call, and the model that asks through
`MCPElicitationTool`.

**Requirements:**

- **Scope each request**: `sessionId` plus `toolCallId` (the MCP call handle
  maps to it; then the client can show *which* tool call asks, including a
  detached long call that would otherwise ask with no context); or a
  `requestId` for interactions outside a session.
- **Gate on capability. Degrade honestly. The gate is `_meta`.** Stable v2's
  `ClientCapabilities` has only `_meta`. Thus elicitation support is a
  `_meta`-negotiated extension while `elicitation/*` is unstable. Absent means
  unsupported (§5). When the necessary mode is unsupported, return MCP
  **`decline` with a clear reason**. Do not compress into
  `session/request_permission`. That method is options-based. It cannot carry
  a `requestedSchema`.
- **Relay the URL-mode completion.** Create → accept → `elicitation/complete`
  is a three-message flow. Send MCP's completion notification through,
  directly. The ids agree by design.
- **Obey the spec's security duties** (they are ours, as the agent): form mode
  MUST NOT ask for secrets. URL-mode credentials MUST NOT come back over ACP.
  **Agents MUST NOT fall back to form mode when URL mode is unavailable.** URL
  mode exists because the data is sensitive. Thus the only correct response to
  "URL unsupported" is a decline. The agent MUST make sure that the
  authenticated user identity is the same at start and at completion. Use
  HTTPS outside development. Do not prefetch.
- A client that returns `-32602` (unsupported mode) reports **our** defect. We
  must not have asked for that mode. `elicitationId` must be unique among the
  *outstanding URL elicitations on the connection* (a smaller scope than
  global). `elicitation/complete` goes only to the client that received the
  create. Key on the connection, not the session.
- **Do not stop the model.** Each round-trip is in Router's `awaitingUser { }`,
  paired with `state_update: requires_action`. The gate release and the state
  transition are two halves of one action (§8.2).

**The gate, and the interim.** `elicitation/create` / `elicitation/complete`
exist in the unstable schema as **method names only**. There are no generated
types and no handlers. (The docs show a `capabilities.elicitation` field. The
stable schema does not have it.) The wire package must land the types and the
client-side handler entry points first. Thus **this is not day-one scope.**
Upstream has promoted elicitation to stable on its main branch. A schema
re-vendor brings the types. The work is filed on the wire package's board:
`7kgq5dw`, then `enzjy0q` (§21).
The interim: `FoundationModelsMCP`'s coordinator gets a non-ACP fallback. It
declines each elicitation with a clear reason: "this host cannot ask you
questions yet". That is honest, and it unblocks the MCP built-in without the
unstable surface.

## 17. Transports

**Framing** (these are protocol MUSTs, not house style): messages are UTF-8
JSON-RPC. `\n` divides them. A message MUST NOT contain a newline. There is no
content-length header. The agent **MUST NOT write non-ACP content to stdout**.
The gated integration test (§20.1, tier 3) asserts this MUST. stderr is free
for logs. The client can capture, forward, or ignore it.

**Consumers**: external clients speak ndJSON over stdio (`<cli> acp`; the
production CLI and the ACP agent are the same binary). The Mac app uses
`InMemoryTransport.pair()` in-process (§19). The connection is full duplex,
not request/response: `session/prompt` returns `{}` immediately, and the full
turn arrives as notifications on the same pipe (§8.1).

**The wire package already does these** (do not build them again): frame
serialization (`StdioTransport` writes under a lock; concurrent sessions
cannot make a torn line), respond-then-notify order
(`afterRespondingToCurrentRequest(_:)`), and lifecycle (the client starts the
agent as a subprocess and stops it; the agent reads until stdin EOF; there is
no teardown handshake).

**Batching** is permitted by the spec. But "initialize, auth, and session
operations SHOULD NOT be batched". That covers almost everything this agent
handles. Thus batch handling stays the wire package's concern. It does not
become a sequence hazard here.

**Defend against one hazard: subprocess stdout.** `shell` spawns children. A
child that *inherits* the agent's stdout writes into the ACP frame stream.
That damage is invisible to unit tests, because the tool itself was correct.
Shelltool captures child output. It does not let children inherit. Tier 3
(§20.1) proves this, end to end.

## 18. Extensibility

- **Each extension goes in `_meta`, never adjacent to it.** Implementations
  MUST NOT add custom fields at the root level of spec-defined types. All root
  names are reserved for future protocol versions. This covers the elicitation
  capability gate (§16) and each other extension that we think of. Root-level
  `traceparent` / `tracestate` / `baggage` are reserved for W3C trace context.
  Obey them if we send tracing.
- **`_`-prefixed values are the extension mechanism for extensible enums.**
  Values that start with `_` are implementation-specific. Unknown values
  without the underscore are reserved for future ACP variants. Implementations
  MUST NOT handle them as custom extensions. This makes `_lost` (§11.5)
  legitimate. A bare `lost` would take a name that the protocol keeps for
  itself.
- In a proxy, keep unknown values (SHOULD). Show unknown variants with generic
  UI (SHOULD). Do not drop them.

---

# Part III — Beyond the protocol

## 19. Frontends: the shared-consumption contract

Three consumers share this composition: the Mac app, the CLI, and each ACP
client (Zed, editors). We do not *build* the app and the CLI here. We *prove*
each contract here.

- Both construct this package's composed agent with the **same dotfolder
  name** (§2.1). That one string makes the config and transcripts shared.
- **The CLI is a thin ArgumentParser wrapper**: parse args → construct the
  agent → render the session event stream. `Examples/acp-agent` (§20.2) is
  this CLI in miniature, and it is also the living contract test. The
  production CLI grows in its own repo, from a copy of it. `<cli> acp` speaks
  ndJSON over stdio.
- **The Mac app is itself an ACP client, in-process**, through
  `InMemoryTransport.pair()`. It is the same interface that Zed uses, over a
  different transport. The app puts the ACP event stream in `@Observable`
  containers and binds them to SwiftUI. A direct bind to Router would make a
  second, drifting path to the UI, adjacent to the one that each external
  client sees.
- **Infrastructure state still comes from Router, directly.**
  `ResolutionProgress` (model download/load, residency) is not session
  content. ACP has no notification for it. The rule of the split: **session
  content flows over ACP; infrastructure state comes from Router.**
- The history browser uses `TranscriptStore.allProjects()` /
  `sessions(inProject:)`.
- **Sandboxing**: shared `~/.config/<name>` plus access to all project
  directories is not compatible with the App Sandbox. The Mac app ships
  **without a sandbox**. (It is a developer tool that operates on all repos;
  that is the norm for this product class. It can still be notarized, with
  the hardened runtime.) If a sandbox becomes mandatory: use security-scoped
  bookmarks for each project, and move the home layer to
  `~/Library/Application Support/<name>/`, with the CLI on the same path. The
  `DotfolderStack` seam keeps that change local. Decide before the app ships.
  Nothing in this package waits on it.

### 19.1 The record, the interface, and the observable container

Three representations, in a strict derivation order. Do not reverse the order:

```
Transcript (FoundationModels)          THE RECORD — journaled append-only (§8.5)
   |  Router projects changes
SessionEvent  +  SessionProjection     keyed on Apple's own Transcript.ToolCall.id
   |  this package maps (§8.4)
ACP session/update                     THE INTERFACE — the wire stream
   |  InMemoryTransport (in-process) or stdio (external clients)
ACP Client conformance = @Observable   SwiftUI binds this
```

- **ACP is a projection, never a second record.** Each `session/update` must
  be derivable from the transcript. The result that makes this safe: an
  observable container must be able to **rehydrate** through `session/resume`
  + `replayFrom: start` (§7.4). It must not only accumulate from a live
  stream. The stream can start late, or lose messages.
- **Coalescing is a requirement, not an optimization.** `textDelta` arrives at
  token rate. If each delta goes to an `@Observable` on the main actor,
  SwiftUI thrashes. Collect deltas and flush at display rate. Append into the
  in-flight message.
- **The transcript stays reachable, directly.** The frontend gets the session
  (and thus its `Transcript`) for authoritative inspection, history, and
  debugging. That is a second *view* of a derived-from source. It is not a
  second source.

## 20. Testing

### 20.1 The test ladder — five tiers, only two need a model

The organizing question: **"do the tools work" and "does the model use the
tools" are different questions.** Only the second needs a model.

| Tier | Model | Client | Tools | Gated | Answers |
|---|---|---|---|---|---|
| 0 — unit | — | — | — | no | do the tools work in isolation *(done upstream: FileTool 461, Shelltool 298, Router 624 tests)* |
| 1 — golden conformance | scripted | recording sink | fake | no | is the wire shape right — ordering, upserts, replay |
| 2 — tool integration | scripted | recording sink | **real** | no | do real tools work through the real conformance |
| 3 — stdio contract | scripted | subprocess | real | yes | does framing survive a real process boundary |
| 4 — eval | **real** | in-process | real | yes | does the model *choose* to use tools, and succeed |

**There is no "fake client" to build. `ClientSideConnection` is the client.**
A `Client` conformance is about ten lines:

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

That is a **sink**, not a simulation. Each tier above tier 0 uses these same
ten lines.

**Tier 2 is the tier that answers the question.** A real `ToolCatalog`, a real
`FileTool` and `Shelltool`, a real `RoutedACPAgent`, a real `session/new(cwd)`
against a temp directory — with a scripted *model*: inject a `ModelLoader`
whose `LoadedLLMContainer.makeSession` returns a `LanguageModelSessionBackend`
that sends a known tool call. (Router's own `ScriptedOverflowBackend` proves
the pattern. No upstream change is necessary.) There is no MLX, no download,
and no Apple-silicon gate. It runs in CI at each commit. Only tier 2 proves
these:

1. **Composition**: `ToolCatalog` constructs each tool with the correct
   `ToolContext`: the root set from `cwd` + `additionalDirectories`, and that
   tool's decoded config section.
2. **Confinement through the protocol**: ask `files` for a path outside the
   root set, and get a refusal, from the client end.
3. **Projection**: a real tool call becomes a correct `tool_call_update`: a
   stable `toolCallId`, `in_progress` → `completed`, filled `locations`,
   `rawInput`/`rawOutput`, and the `title` on the first report.
4. **Turn order**: `{}` → `user_message` → `running` → tool updates →
   `idle(end_turn)` (§8.1).
5. **Enable/disable**: `shell: false` in the project config means that no
   shell tool reaches the session. We confirm this from the client end.

**The rule that makes tier 2 reliable: check the filesystem, never the
transcript.** If the test says that a file was written, read the file from
disk. Do not believe a `tool_call_update` that claims success. This is the
same discipline as §20.3's evaluators. It divides a test that catches a broken
tool from a test that only catches a broken *report* of a tool.

**MCP gets tier-2 coverage free**, when `4egfvw3` lands. `FoundationModelsMCP`
ships `MCPTestServerCLI` and a `ScriptedServer`. Spawn a real server process.
List its tools. Call one. Confirm that the `tool_call_update` correlation
holds.

**Tiers 3 and 4 stay gated, and stay small.** Tier 3 exists for the one thing
that tier 2 cannot see: real process boundaries. stdout carries only ndJSON
while `shell` runs subprocesses that write to *their* stdout. And no message
contains a newline. (Both are protocol MUSTs, §17.) Tier 4 is §20.3.

### 20.2 `Examples/acp-agent` — the example program and the tier-3 fixture

**One executable serves the two purposes, intentionally.** The family
convention is an `Examples/` directory of runnable programs. The example that
this package owes is "how do I build an ACP server CLI on top of this?". That
is exactly what tier 3 must spawn. If we write it two times, the example
decays while the fixture stays green.

`Examples/acp-agent/main.swift`. Keep it small enough to read in one sitting.
The composition is the lesson:

```swift
// 1. the dotfolder name is the frontend's choice (§2.1) — everything else derives
let agent = try await RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)

// 2. serve ACP over stdio; stdout is sacred, logs go to stderr
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in agent }
await connection.run()
```

The example must show: the selection of the dotfolder name and what it
controls; service over `AgentSideConnection(stream: .stdio)`; logs to stderr
only; and where a frontend adds its own tools to the merged roster (§11.1). It
must *not* grow into a second product: no argument parsing beyond stdio
service, no rendering, no config wizardry. An example written as a
read-request/write-response loop deadlocks when it sends a mid-turn update.
Thus the full-duplex shape (§17) is a lesson as much as a function. (The wire
package's `acp-test-agent` is the contrast: it answers `initialize` and
nothing else. Ours composes the real runtime and real tools.)

### 20.3 Evaluations — `PythonCLIEvaluation`

The end-to-end coding eval belongs to the layer that composes the roster.
(Router keeps its compaction eval over sample tools.) The eval drives real
`files` + `shell` through a real multi-turn build task, on Apple's Evaluations
framework (swift-testing native). It is gated on Apple silicon + real models +
network:

1. **Subject**: `subject(from sample:)` makes a fresh temp workspace (the
   session's `workingDirectory` and the tools' confinement root). It wires
   recording to a temp location. It constructs the composed agent with real
   `files`/`shell` and the coding instructions. It runs to completion. It
   returns the workspace path + the transcript + the run stats.
2. **Dataset**: an `ArrayLoader` of `ModelSample`s. Each is a variant of
   "build a small Python CLI" (`pyproject.toml`, a third-party package such as
   `click`, the CLI, pytest tests, a project-local venv, pytest green, then
   run it). `expected` carries the fixed input/output pair. Start with 20–30
   hand-written samples, per Apple's guidance. Scale later with
   `SampleGenerator`.
3. **Evaluators: mechanical, and confirmed outside the agent.** They do not
   trust the transcript's claims. One `Metric` each: `PytestGreen` (runs
   pytest again in the venv; exit 0), `CLIRuns` (runs the CLI against
   `expected` and checks the output), `FilesPresent`, `ToolTraffic` (the
   transcript contains `files` and `shell` calls).
4. **Aggregation**: `MetricsAggregator.computeMean` for each metric. The
   `@Test` asserts the mean pass rates against thresholds. The turn count, the
   tool-call counts, and the token usage ride along, keyed by the resolved
   model from `manifest.json`.

Isolation: everything stays in the temp workspace. The venv is in it. There is
no system-Python change. There is no network beyond the package install.
Delete the workspace after grading. (Keep the transcripts for failed runs.)

## 21. Upstream dependencies

| Id | Package | What | Status |
|---|---|---|---|
| `f9q2338` | FoundationModelsShelltool | build `ShellPolicy` from values, host-owned persistence (§2.5); the Extras dependency is gone | **landed** 2026-07-29 |
| `c2pad49` | FoundationModelsExtras | third `SlashCommand.Body` case, `.rendered` (§14.2) | **open** — workaround available, prefer the case |
| `939nnzx` | FoundationModelsFileTool | multi-root `PathGuard` (§7.2) | **in progress** — the only blocker for `additionalDirectories` |
| `4egfvw3` | FoundationModelsMCP | needed for tier-2 MCP coverage via `MCPTestServerCLI` (§20.1) | open |
| — | FoundationModelsRouter | in-flight turn cancellation (§8.6) | **open** — until then, "we stopped listening" |
| `7kgq5dw` → `enzjy0q` | FoundationModelsACP | schema re-vendor (upstream promoted elicitation to stable), then generated `elicitation/*` types + `Client` entry points (§16) | **filed** 2026-07-29 — the wire is otherwise done: stable v2 verified, 95 tests green |
| `kdvsjmj` | FoundationModelsACP | `mcp/*` tunnel payload types (§11.5) | **filed** 2026-07-29 — blocked until upstream stabilizes `mcp/*` |
| `ke41yth` | FoundationModelsRouter | per-session recording root, flat `<root>/<sessionId>/` layout (§4.1) | **landed** |
| `kh01tv2` | FoundationModelsRouter | pooled, reference-counted model residency → per-project profiles (§7.1) | **landed** |
| `6j4bven` | FoundationModelsRouter | checkpoint-aware session restore feeding `session/resume` (§7.4) | Router board |
| M1–M3, M5 | FoundationModelsSkills | the `/id` command half (§14.2) | plan-only |
| M4 (+ Operations 2/4/5, MetadataRegistry M1–M4) | FoundationModelsSkills | the model-facing tool half (§11.3) | plan-only; follow-up |
| `d7jwam5` | FoundationModelsFileTool | *note, not an ask*: rename/copy path mapping is a translation here (§11.6) | — |
| `1ad4ydw` | FoundationModelsOperationTool | shared `OperationOutcome` terminal vocabulary on the `OperationEvent` envelope — feeds the one total status mapping (§8.4, §11.5) | **landed** |
| `jt19xwc` | FoundationModelsShelltool | emits `OperationOutcome` on detached-command terminal events (§8.4) | **landed** |
| `zfp4a3j` | FoundationModelsMCP | emits `OperationOutcome` on call terminal events (§8.4, §11.5) | **landed** |
