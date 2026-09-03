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
                    │      token-metered, event-streaming, recorded)
                    │      NOTE: restore is not public today — see §4.6
                    ▼
   FoundationModelsExtras (DotfolderStack, TemplateEngine, SlashCommand, AgentsMd, LayeredYAMLDocument)
```

**Dependencies.** This package depends on the ACP wire, Router, Extras, and
two tool packages: **`FoundationModelsMultitool`** — the consolidated tool
surface (see that package's `eventplan.md`) — and **`FoundationModelsSkills`**.
Multitool holds three built-in capability modules: `shell`, `files`, and
`mcp`. The former sibling tool packages Shelltool, FileTool and MCP dissolve
into those modules. **Skills does not dissolve into Multitool.** Skills is a
standalone package that gives one plain `FoundationModels.Tool`. Neither
package depends on the other, in either direction (§14.2).

Multitool has no `@_exported import`. Therefore this package declares its own
dependencies on `FoundationModelsRouter`, `FoundationModelsExtras`, and
swift-sdk's `MCP` to name those types. Use the org fork
`https://github.com/swissarmyhammer/swift-sdk`, branch `main`. Do not also
depend on `modelcontextprotocol/swift-sdk`: two identities of the same package
cause a resolution conflict. `swift-subprocess` is pinned `exact:
"1.0.0-beta.1"`. Multitool has no semver tags, so depend on `branch: "main"`.
**The platform declaration is the string form `.macOS("27.0")`.** Router,
Multitool and Skills all declare it. Our `Package.swift` still declares
`.macOS(.v26)`; change it to the string form so the dependency graph resolves.

The `FoundationModelsOperationTool` **package** is removed. The
`OperationTool` **type** is not removed: it lives in Extras at
`Sources/Operations/OperationTool.swift` and ships as Extras' `Operations`
product. Skills is built on it today. The event vocabulary (`OperationEvent`,
`OperationOutcome`) lives in Extras, and Router re-exports it as typealiases
in `Hosting/OperationVocabulary.swift`. Code mode replaces the fused-operation
pattern in Multitool only. Only this package gives names to tool packages. The
runtime may not do this. No cycle is possible: Multitool does not depend on
this package.

**The test target and the `Examples/` executables also depend on the sibling
`FoundationModelsACPClient`, the Client role.** It is the client driver for
every integration tier (§20.1) and for `acp-print` (§20.2). The library
target never imports it. The client depends on the wire and Extras only, so
no cycle is possible there either.

**The composition, end to end:**

```
config  (dotfolder stack, §2)
  → ProfileDefinition → Router.resolve → resident profile
  → tools         (§11: config sections → Multitool capability modules
                    → searchTools + runCode + wait; plus the standalone
                      skills tool the catalog appends)
  → instructions  (Instructions.md + AGENTS.md, §3)
  → per session:  profile.standard.makeSession(instructions:workingDirectory:
                    recordingRoot:tools:budget:compactionPrompt:summarization:
                    agentSpawn:discoveryPriming:)  ← the self-folding session
  → RoutedACPAgent(name:router:configuration:commands:)  ← `name` is the
                    dotfolder name the frontend chose (§2.1)
```

**`makeSession` is not on `Router`.** `Router` has exactly three public
members: `id`, `init`, and `resolve(profile:reporting:)`. A session comes from
a model handle on the resolved profile:
`RoutedLLM.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)
-> RoutedSession`, or the overload
`RoutedLLM.makeSession(configuration: SessionConfiguration)`.
`SessionConfiguration` carries the same fields plus `grammar`; a non-nil
`grammar` vends a guided session.

**`agentSpawn:` stays `nil` in this iteration.** Agents are not implemented
yet. A later iteration adds them as a Multitool capability behind the
code-mode surface, as a long-running background tool (§11.3).

**Trap: a `RoutedModel` holds its owning profile weakly.** Every public
`makeSession` calls `preconditionFailure` if the profile is already released.
Only the vended session retains the profile. Therefore the agent must hold the
resident profile for the full life of the process.

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
`mcp/*` and `session/fork` are in the **unstable schema only**.
**`elicitation/*` is stable, and the wire package ships it**: the vendored
schema is `schema-v2.0.0-alpha.3`, `ClientCapabilities.elicitation` is a
generated field, and `AgentSideConnection` has `createElicitation(_:)` and
`elicitationComplete(_:)` (§16, verified 2026-09-01). We plan all three, and
we gate them (§16, §11.5, §7.5). `session/list` /
`resume` / `close` are baseline in v2. Each agent that supports sessions must
supply them. "Capability off" is not available for them.

**One identity goes through the full stack.** Apple's `Transcript.ToolCall.id`
= Router's `SessionEvent.toolCall(id:)` = ACP's `toolCallId` = the MCP call
handle = Router's `OperationEvent.correlationID` = Multitool's
`completionToken` = `AgentSpawn.parentToolCallId`. This
is one stable key across the full stack. The key correlates the wire's tool
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
| *(no per-tool config files — tools take **objects**, §2.5)* | — | — | there is no `decisions.yaml`; the shell permission layer is deleted (§2.5, §11.7) |

`AGENTS.md` is the one **additive** row. It answers "in which order do the
files compose". Each other row answers "which layer wins".

### 2.4 Schema and loading

**The `AgentConfiguration` schema** contains `profile` (standard/flash/
embedding slots), `tools` (built-in sections + `mcp`, §11.2), `recording`,
`transcripts`, `compaction`, and `sandbox` (§11.7). There is **no
`permissions` section**: the sandbox is the only gate, and it has no policy to
configure (§11.7). The `sandbox` section holds one key, `extraWritePaths`.
There is **no `instructions` section**. The
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

### 2.5 Capability modules take objects, not config files

**Only this package reads configuration. Multitool's capability modules
receive constructed values.** No capability module reads its own config file.
No capability module names a dotfolder convention. The mechanical test: **a
capability module that depends on Extras' `DotfolderStack` does configuration
that it must not do.** Each module gets its values through its `Builder`
call:

| Capability (Builder call) | Takes | Status |
|---|---|---|
| `files` — `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:)` | `root: URL`, `additionalRoots: Set<URL>`, three flags | ✅ complies |
| `mcp` — `withMCP(servers:) async throws` | `[MCPServer]` | ✅ complies |
| `shell` — `withShell(storeDirectory:sandbox:outputChunkStream:) throws` | an optional store directory, an optional `any CommandSandbox`, an optional `ShellOutputChunkStream` | ✅ complies |
| *(anything else)* | `withCapability(_:)`, `addTool`, `addTools`, `register(noun:tool:)`, `addGroup(named:_:)` | the open door for a host-supplied capability |

The build calls are `build() throws -> APISurface`, `buildRegistry() throws
-> MultiTool.Registry`, and `rebuildRegistry() async throws ->
MultiTool.Registry`.

**There is no `withSkills(roots:)` and no `withAgents(...)`.** Skills is a
standalone package, not a Multitool capability (§1, §14.2). Do not look for a
builder call for it.

**The shell permission layer is deleted.** Upstream removed it on 2026-08-24.
These types exist nowhere now: `ShellPolicy`, `ShellPolicy.builtinRules`,
`.merged(with:)`, `ShellSecurityConfig`, `ShellDecisionStore`, `ShellContext`,
`check(workingDirectory:)`, `remember(...)`, the `.allow` / `.ask(reason)` /
`.deny(message)` results, and the `decisions.yaml` file. There is no policy
layer. There is no remembered `allow_always` / `reject_always` store. There is
no denial-union rule, because there are no denial rules.

**The upstream reason, recorded here:** a denylist over command text is
bypassable. The sandbox is a kernel boundary. It does not care how a command
is spelled.

**`SeatbeltSandbox` is the only gate on a command.** It conforms to
`public protocol CommandSandbox: Sendable`, which declares
`wrap(...) throws -> SandboxedInvocation` and
`preflight(workingDirectory:temporaryDirectory:) async throws` (default
no-op). The host builds
`SeatbeltSandbox.Options(writableRoots: [String] = [], extraWritePaths:
[String] = [])` from the session root set and passes the sandbox to
`withShell(sandbox:)`.

- **Hard precondition:** every directory given to `wrap` must already be
  `realpath(3)`-resolved. `URL.resolvingSymlinksInPath()` does **not** satisfy
  this on macOS: it strips `/private` and gives exactly the form that Seatbelt
  cannot match. `SeatbeltSandbox.Options.init` runs `resolvedPath` over both
  lists for you.
- `preflight` runs a canary before any command starts. A failed preflight
  means the command does not run. There is no path from a failed preflight to
  an unconfined spawn.
- **Stated limit:** the sandbox bounds writing and deleting only. Reads are
  free and the network is open. Therefore exfiltration is not bounded.

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

**Discoverability obligations** (the cost of a compiled-in floor): the README
links to the source file that holds the builtin text, and a test asserts the
link resolves. The README does not repeat the text — one copy only, because a
second copy goes stale. The CLI can print the assembled prompt. The
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
- **Preloaded skill bodies join the prompt here, and this layer owns that
  step.** Call `registry.preloadedBodies()` (§14.2). It returns the bodies of
  the `preload: true` skills, already rendered, as **one** `String`. Append
  that string after the rendered base prompt and before the `AGENTS.md`
  documents. **Refresh it when the skills registry reloads.** A `nil` or empty
  registry adds nothing.

The untrusted render is validated and has no side effects. It has no
filesystem or exec reach. Budgets meter the include depth, the loop
iterations, and the output size. Thus a hostile `Instructions.md` in a cloned
repo has the same limits as each other untrusted document.

### 3.2 Agent-instructions files — `AGENTS.md` via Extras' `AgentsMd`

These files are context, not memory. Per [agents.md](https://agents.md/),
`AGENTS.md` is "a README for agents". Nothing here keeps data across sessions.
The discovery walk is Extras' `AgentsMd`. This layer consumes the walk.
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

**Assembly order:** the base prompt (`Instructions.md`, §3.1) → the preloaded
skill bodies (`registry.preloadedBodies()`, one rendered string, §3.1 and
§14.2) → the user-level
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

**Router's on-disk layout, confirmed.** With `recordingRoot` set, a session
records to `<recordingRoot>/<sessionId>/`. Build the read side (§4.6) on these
facts:

- **A fork nests inside its parent's directory, and the nesting *is* the
  lineage record.** No file stores a parent path.
- **Identity is the directory name, and it must parse as a ULID.**
- **A directory is a session if and only if it holds `session.json`.**
  `session.json` is write-once.
- **`transcript.jsonl` is append-only.** It fsyncs only after a `.response`
  event. Therefore the final line can be torn after a crash. A reader drops a
  torn **final** line with a warning. A corrupt **earlier** line throws.
- **`seq` is global across directories.** The merge sorts by `(ts, seq)`.

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
   `parentId == nil` and there is no agent spawn. **Read both halves from
   `TranscriptEvent`, not from the sidecar.** `SessionSidecar` is public but
   publishes **no** public stored property at all. What is public is the
   nested type `SessionSidecar.AgentSpawn` and the `init(from decoder:)`.
   Therefore a caller can decode a `session.json` that it already located, but
   it can read no field from the decoded value. `TranscriptEvent.parentId` is
   public and arrives with `merged(under:)` (§4.6).
- **`session/close` closes the tree**: a fork or sub-agent that operates is
  part of the session's work (§10.1).

**Where a sub-agent's transcript goes:** under the project root of the
sub-agent's own cwd. A sub-agent in a different repo goes in *that* repo's
transcripts. `parentToolCallId` links it, as a sibling. Forks share the parent
conversation. Thus forks stay nested under the parent, as before.

**Status: agent spawns do not occur in this iteration.** Agents are not
implemented yet. No tool in the roster starts a sub-agent, and `session/new`
passes `agentSpawn: nil` (§7.1). A later iteration adds agents as a Multitool
capability behind the code-mode surface, as a long-running background tool
(§11.3). The rules in this section stay in force now, because the read side
(§4.6, §9) and the close path (§10.1) must already accept a spawned session
when that capability arrives. Until then, only a test fixture can make one,
through `makeSession(agentSpawn:)`.

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
  per-project. **`RecordingLevel` has only two cases: `off` and `full`. There
  is no `metadata` level.** Therefore the only choice is full recording or no
  recording. There is no middle escape hatch for repo size. Say this in the
  docs, clearly: full transcripts are the default because they are the
  valuable thing, and they are not free.

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

**`recording.level` stays the control for repos that want less.** The level is
`full` or `off`, and nothing between: `off` records nothing. Commit the level
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
`transcript(for sessionID:)`.

**Build the read side on `TranscriptEvent.merged(under:) throws ->
[TranscriptEvent]`. It is the only public read that Router gives.** It returns
one flat list, sorted by `(ts, seq)`, with no tree. Group the list by
`sessionId` and rebuild parentage from `parentId`. The public fields are
`sessionId`, `parentId`, `slot`, `seq`, `kind`, `text`, `tokensIn`,
`tokensOut`, `ms`, and `entry`. The fields `routerId`, `model`, `ts` and
`grammar`, and the initializer, are all internal.

**Session restore, list and delete are not public.** `restoreSessionTree`,
`RestoredSessionTree`, `transcriptTree(recordingRoot:)` and
`makeLanguageModel(resuming:)` are internal. `TranscriptTree.load(under:)`,
`.roots`, `SessionNode` and `effectiveTranscript(forSession:view:)` are
package. Therefore live resume is **blocked** on an upstream Router ask for a
public restore entry point (§21). We sent the ask on 2026-08-31, and the
decision is pending. **We will not reimplement restore against
`transcript.jsonl`.** That forks Router's format, and it breaks silently at
the next format change.

Two smaller gaps to expect:

- `SessionSidecar` is public, but it has **no** public stored property at all.
  Only the nested type `SessionSidecar.AgentSpawn` and the
  `init(from decoder:)` are public. Therefore a caller can decode a
  `session.json` that it already located, but it can read no field from the
  decoded value. Take `parentId` and the spawn fact from `TranscriptEvent`.
- No shipped `TranscriptRecorder` is reachable: `.jsonl`, `.inMemory` and
  `.none` are internal. Therefore a test cannot build a recording fixture
  (§20.1).

The ownership boundary: **`TranscriptStore` does not record and does not
restore.** It owns the root location policy, the project registry, and light
browse summaries. Router owns everything that gives a `transcript.jsonl` its
meaning: event writes, entry reconstruction, compaction checkpoints, and
live-session rebuild. This package calls Router for those.

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
This is the spec's own MUST. Stable v2's `ClientCapabilities` has two
fields: `auth` (`terminal`) and `elicitation` (`form`, `url`). Each is an
object or absent. We read only `elicitation` (§16): an omitted or `null`
`elicitation` means the client cannot ask the user anything; `form` and `url`
are present, non-null objects only when that mode is supported. We never read
`auth.terminal`, because we have no auth (§6). The generated type is
`ClientCapabilities.elicitation: ElicitationCapabilities?` with `form:
ElicitationFormCapabilities?` and `url: ElicitationUrlCapabilities?`.

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
+ the assembled instructions (§3) → `profile.standard.makeSession(...)` (§1).
`cwd` MUST be
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
  location. **`PathGuard` is internal, so a consumer cannot name it.** Reach
  multi-root confinement only through
  `withFiles(root:additionalRoots:)` (§2.5). The shell side takes the same
  root set as `SeatbeltSandbox.Options(writableRoots:)` (§11.7).
- **On resume, the list is authoritative and replaceable. It is not sticky.**
  A non-empty list is the complete resulting root set. Omitted or empty means
  **no** additional roots. Do not inherit the session's former roots. Rebuild
  confinement from the request contents, each time. This keeps a boundary that
  the client made narrow from silent re-widening.

Upstream: multi-root `PathGuard` (`939nnzx`, in the files capability) is
**done and shipped**. Nothing here blocks. The shell capability is not
root-confined by a guard; `SeatbeltSandbox` bounds its writes (§11.4).

### 7.3 `mcpServers` — the client's servers

`session/new` and `session/resume` both carry `mcpServers: [McpServer]`.
Client-supplied servers have session scope. We connect them **in addition to**
the config-derived servers, after them. (ACP's `name` is our
`ServerIdentity`, which is exactly `{ name: String }`.) **The server name is
the noun**: a verb mounts as `tools.github.createIssue`, never
`tools.mcp.github.createIssue`. There is no `tools.mcp` group. Therefore a
name collision is a noun collision. **The collision rule is decided**, and
`MCPComposition` implements and documents it: we **refuse** a
client-supplied server whose name collides with an already accepted server —
a config-derived one, or an earlier client-supplied one. The refusal is
logged, and the session still starts. Config is the user's own committed
intent; a silent replacement would let a connecting editor shadow a trusted
server. Connection must complete **before** the tool array reaches
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
  session itself. **This is blocked today: Router's restore entry points are
  internal (§4.6).** We sent an ask for a public entry point to the Router
  team on 2026-08-31. The decision is pending, and it is escalated to that
  team's user, because publishing a restore entry point is a substantial
  public-surface commitment. **Do not reimplement restore against
  `transcript.jsonl` while the decision is pending.** That forks Router's
  format, and it breaks silently at the next format change (§21).
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

**`turnEnded` is not the end of the turn.** Router emits it once for each
inner generate call. A turn that retries after a recovered overflow emits one
`turnStarted` and two `turnEnded` (§8.4). Therefore the `idle` update must key
on the completion of our own turn task, not on a `turnEnded` event. Sum the
usage across every `turnEnded` in the turn. Report that sum one time. Two
`turnEnded` events are one turn, not two turns. Send `idle` one time.

### 8.2 The state machine

`state_update` carries `running` / `idle` / `requires_action`. The conformance
needs a named owner for this state machine:

- `running` at turn start.
- **`requires_action` each time we stop on the human**: around each
  elicitation round-trip (§16). We send no permission requests (§11.7).
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

**`SessionEvent` has thirteen cases. Handle all of them.** The enum has no
library evolution, and its doc comment says a consumer must write a `default`
arm. Write one.

| Router `SessionEvent` | ACP `SessionUpdate` (v2 discriminator) |
|---|---|
| `turnStarted(TurnStart)` | `state_update: running` |
| `textDelta(String)` | `agent_message_chunk` (with the agent-generated `messageId`) |
| `textReset` | a **whole-message** `agent_message` upsert that replaces the accumulated content (§8.3, row 3) |
| `reasoningDelta(String)` | `agent_thought_chunk` |
| `toolCall(id:name:argumentsJSON:)` | `tool_call_update` — v2 has no `tool_call` create variant; the first update carrying an unseen `toolCallId` *is* the creation, and SHOULD carry `title` |
| `toolStatus(id:status:summary:output:)` | `tool_call_update` (`running` → `in_progress`) — `output: [SegmentPayload]?` is the fourth parameter; map it to the call's content |
| `toolInvocation(ToolInvocationRecord)` | `tool_call_update` — the settled record for the call |
| `entryRecorded(id:kind:)` | nothing on the wire — a recording fact (§4) |
| `compaction(CompactionResult)` | `usage_update` — the context meter drops; no message change (§8.5) |
| `discoveryPrimingFailed(DiscoveryPrimingFailure)` | nothing on the wire — log it |
| `generationStalled(GenerationStall)` | nothing on the wire — log it |
| `runSettled(OperationEvent)` | `tool_call_update` with the **terminal** status (see the mapping below) |
| `turnEnded(TokenUsage)` | `usage_update` only (the `idle` `state_update` comes from the completion of our own turn task, never from this event — §8.1) |

**`textReset` means "discard the text accumulated so far".** Therefore it
cannot ride as a chunk. Send the whole-message form, which replaces
everything accumulated (§8.3).

**One wire update has no `SessionEvent` source: `tool_call_content_chunk`.**
It appends one `ToolCallContent` item to a tool call's content, and a later
`tool_call_update` with `content` replaces the whole array (the tool-call
half of §8.3). Its live source is not Router's event stream. It is the
host-owned `ShellOutputChunkStream` that the catalog passes to
`withShell(outputChunkStream:)` (§11.8): each `ShellOutputEvent` with
`.output(stream:bytes:)` becomes one `tool_call_content_chunk` with a text
`content` item, keyed by the run's `commandID` (= `completionToken`, the
`toolCallId`). The settlement `tool_call_update` from `runSettled` then
carries the complete `content` from the stored record. That final replace is
the convergence step: a client that missed a chunk still ends correct
(§11.6). Decided 2026-09-01.

**Trap: `turnEnded` fires once for each inner generate call, not once for a
logical turn.** A turn that retries after a recovered overflow emits one
`turnStarted` and **two** `turnEnded`. Therefore do not send `idle` at the
first `turnEnded`. Sum the usage across every `turnEnded` in the turn, then
report that sum one time. Two `turnEnded` events are one turn, not two turns
(§8.1).

**Two subscription channels carry different sets. Pick with care:**

| Channel | Life | Carries |
|---|---|---|
| `streamEvents(to:maxTokens:)` | one turn | every case, `textDelta` and `textReset` included |
| `streamSessionEvents()` | the full session | every case **except** `textDelta` and `textReset` |

- **Abandoning a `streamEvents` stream cancels the turn.** It does not drain
  the run plane. Read it to the end, or cancel on purpose (§8.6).
- Each `streamSessionEvents()` call vends an independent subscription with an
  unbounded buffer. `close()` finishes every outstanding one (§10.1).

**Order within a turn**: `turnStarted` → `textDelta` fragments → (after the
turn's diff) the tool-call and tool-status events, `reasoningDelta`, and one
`entryRecorded` for each recorded entry → `turnEnded`. A **proactive** fold's
`compaction` comes **after** `turnStarted` and **before** the rest of the
turn's events: Router emits `.turnStarted` first, then runs the proactive fold
block. A **reactive** fold's `compaction` comes **after** the failed attempt's
`turnEnded`.

The v2 discriminators are **`snake_case`** (`agent_message_chunk`,
`tool_call_update`, `in_progress`). The JSON *properties* are `camelCase`.
This is an easy place for a wire error.

- **`usage_update` is the context meter, and it is native**: `{used, size,
  cost?}` maps to Router's `TokenUsage { tokensIn, tokensOut, contextFill }`
  and the resolved context. **`TokenUsage` has no cost field**, so send no
  `cost`. **Trap: `contextFill` returns `Double.nan` when there is no stamp**,
  and the naming constant is internal. Therefore test `.isNaN` yourself and
  omit the meter for that turn. Do not put a `NaN` on the wire.
- **`session_info_update`** carries title/metadata changes in a session.
  Example: the moment when the first prompt gives a title (§4.6).
- ACP's `ToolCallStatus` is `pending` / `in_progress` / `completed` / `failed`
  / `cancelled`. `pending` (a queued call) and `cancelled` are additions to
  Router's vocabulary. A detached MCP call stays `in_progress` across turns.
- **Router's own `ToolCallStatus` has only three cases**: `running`,
  `completed`, `failed`. Router derives it from the SDK transcript diff, not
  from `OperationOutcome`. Therefore `toolStatus` alone cannot tell you
  `cancelled` from `failed`. The richer terminal vocabulary arrives only
  through `runSettled`.

**Decision: the terminal status comes from `OperationEvent.outcome`, through
one total function `OperationOutcome → ToolCallStatus`.** `runSettled(OperationEvent)`
is the event that carries it to us. That is the mechanism this mapping runs on.

`OperationOutcome` **lives in `FoundationModelsExtras`, not in Router.**
Router re-exports it, with 17 other names, as typealiases in
`Hosting/OperationVocabulary.swift`. The envelope is
`OperationEvent { tool, op, correlationID, kind, detail, outcome,
elicitation }`, where `OperationEventKind` is `progress` / `completed` /
`elicitation`. **Only `.completed` is terminal, and `outcome` is non-nil if
and only if `kind == .completed`.** Therefore key the terminal update on the
kind, and never read `outcome` on a progress event.

**That rule is a convention, not a type guarantee.** The upstream source
states it in doc comments only. Nothing enforces it: the sole initializer is a
plain memberwise `init` with `outcome: … = nil`, there is no precondition, no
assert, and no validating factory, and the `Codable` conformance is
synthesized, so decoding does not validate either. **Therefore the projection
reads defensively.** A `.completed` event with a `nil` outcome, and a
non-`.completed` event that carries an outcome, are both cases that the
projection must survive. Log them and pick a safe status. Do not crash.

**Router contains no `OperationOutcome → ToolCallStatus` mapping. We own this
function.** We write it once, for every event-posting capability. We do not
parse per-capability `detail` payloads to decide status. The mapping:

| `OperationOutcome` (Swift case) | ACP `ToolCallStatus` | Text |
|---|---|---|
| `succeeded` | `completed` | — |
| `failed` | `failed` | the tool's error |
| `timedOut` (wire `timed_out`) | `failed` | names the timeout ("timed out after Ns") |
| `stopped` | `cancelled` | authoritative — the work was killed |
| `cancelled` | `cancelled` | advisory — "we stopped listening" (§8.6) |
| `lost` | **`_lost`** | "we do not know if this ran" |
| `other(String)` | the raw value under the `_` rule (§18) | generic rendering |

- **The Swift case is `timedOut` (camelCase). Its wire string is
  `timed_out`.** Do not mix the two spellings.
- **`timedOut` maps to `failed`, not `cancelled`.** Nobody asked for the
  stop, and the caller must treat the result as an error. The text names the
  timeout, so the failure is explicable.
- **The three upstream semantic rules, recorded:** `.stopped` is an
  authoritative kill, and the work is certainly dead. `.cancelled` is a
  **request only**, and the work may continue. `.lost` is unknowable.
- **`lost` never flattens into `failed`** (the existing decision, unchanged).
  The extensible status **`_lost`** rides with "we do not know if this ran"
  in the text, for clients that ignore custom values.
- **`other(_)` is the carrier for an unknown wire value.** An unknown wire
  value decodes to `.other(rawValue)` and round-trips. Put that raw value on
  the wire under the `_` extension rule (§18), with a generic rendering. The
  function is total: a new upstream outcome degrades the display, never the
  stream.

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
elicitation with the **cancelled** result (§16). Stop the work.
Then send `state_update` `idle` with `stopReason: "cancelled"`. Agents MAY
send updates after `session/cancel`, but MUST send them *before* the idle
update. `idle` + `cancelled` is strictly the terminator. The client has its
own half: it marks unfinished tool calls as cancelled. We send no permission
requests (§11.7), so the client has no permission duty here. We still send
correct terminal tool statuses. But we do not hold the `idle` for that.

**Router's cancellation is no longer queue-side only. It now reaches the
model call.** Use the right call for the right object:

| What you cancel | Call | Result |
|---|---|---|
| the turn in flight | `RoutedSession.cancelCurrentTurn()` | `.requested` / `.noTurnInFlight` |
| a **queued** prompt — **NOT REACHABLE on our surface** | `cancelPrompt(id:)` | `.withdrawn` / `.turnCancelled` / `.alreadyFinished` |
| a background run | `ToolContext.cancel(completionToken:)` | `CancelOutcome` |

`cancelCurrentTurn()` is cooperative and best-effort. Read `.requested` as
"the request was recorded", not as "the model has stopped". It cancels the
`Task` that runs the model call. Therefore cancellation **does** reach the
tools that the SDK invokes. A stream keeps the fragments that it already
yielded. The transcript records a cancelled turn as a failed turn.

**The row for a queued prompt is not reachable on our surface.**
`cancelPrompt(id:)` exists in Router. We never create a queued prompt: a
prompt that arrives while the session is busy is a client error, and we do not
expose Router's prompt queue over ACP (§7.1). The row stays here so that a
reader knows why we do not call it.

**A cancelled turn does not always throw.** It **usually** surfaces a
`CancellationError`, and we must catch that error and map it to
`stopReason: "cancelled"` (§8.2) when it appears. But Router's contract says
that model work which never checks for cancellation runs to completion and the
turn returns its response. The runner re-raises only what the body threw.
Therefore the turn owner must handle both results. Do not assume a throw.

Two limits stay, and we state them honestly:

- **Model work that never checks for cancellation runs to completion.**
  Propagation past a process boundary stays advisory.
- **An in-flight MCP call cannot be forced to stop.** MCP's
  `notifications/cancelled` is advisory. Thus the honest UI result for that
  call is "we stopped listening", not "it stopped" (§8.4, `.cancelled`).

**Abandoning a `streamResponse` or `streamEvents` stream also cancels the turn
behind it.** Therefore never drop such a stream to "move on": that is a
cancellation, and the client will see it as one.

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
only: no `parentId` and no agent spawn (§4.2). Forks and sub-agents do
not show as conversations.

**Both halves of the test read from `TranscriptEvent`, not from the sidecar.**
Router's list and restore entry points are not public (§4.6). The one public
read is `TranscriptEvent.merged(under:)`. Group its flat `(ts, seq)`-sorted
result by `sessionId` and rebuild parentage from `parentId`. `SessionSidecar`
is public but exposes **no** public stored property at all — only the nested
type `SessionSidecar.AgentSpawn` and the `init(from decoder:)` are public. A
caller can decode a `session.json` that it already located, but it can read no
field from the decoded value. Therefore the sidecar can supply neither
`parentId` nor the spawn fact.

## 10. Session Management (`session/close`, `session/delete`)

### 10.1 `session/close`

This is a **MUST**: cancel the session's work "as if `session/cancel` had been
called", then release the resources. That includes cancellation's full
semantics (§8.6). Answer each pending elicitation with the **cancelled**
result (§16). We send no permission requests (§11.7). A
close during an active turn **sends `state_update` `idle` with
`stopReason: "cancelled"` before the close response**. If not, a client with a
spinner does not learn that the turn ended. Then release: in-flight MCP calls,
detached work, spawned stdio server processes (§11.5), **and the session's
descendants**. A fork or sub-agent that operates is this session's work. If it
continues after close, it burns a model gate with no watcher. That is the
failure that this MUST prevents. Recording closes. The transcript **stays** on
disk.

**`RoutedSession.close()` does most of this for us.** It runs
`SessionMailbox.sweep()`: it cancels every background run, rejects every
pending elicitation, journals the terminal events, and finishes every
`streamSessionEvents()` subscription. It is idempotent, so a double close is
safe. **`deinit` does not run the sweep. The host must call `close()`.**
Therefore `session/close` calls it, and so does agent shutdown.

**The unknown-id policy (decided 2026-09-01).** The spec says an agent MAY
return an error when a `session/close` names a session that does not exist
or is not active. We make one rule for every session method:

| Request | `sessionId` unknown | known, but closed |
|---|---|---|
| `session/prompt`, `session/set_config_option` | JSON-RPC invalid params (`-32602`), the id in `data` | `-32602`, reason "closed; resume it first" — a closed session is resumable (§9), not promptable |
| `session/resume` | `-32602` (a deleted session is unknown, §7.4) | success — this is what resume is for |
| `session/close` | `-32602` | success `{}` — close is idempotent, as `RoutedSession.close()` is |
| `session/cancel` | a notification, so no response: log and ignore | log and ignore |
| `session/delete` | silent success (§10.2) | success — the delete proceeds |

Silence for an unknown id would hide a client bug: a client could prompt a
conversation that does not exist and see `idle` for nothing. The wire package
supplies the error values: `RequestError.invalidParams` is the bare form, and
`ACPError(code: .invalidParams, message:data:)` carries the id and the
reason. Use those, never a bare integer.

**The shutdown order matters**: sweep the sessions first, then call
`MCPServerPool.shutdownAll()` (§11.5). A pool shutdown before the sweep drops
the transports that the settling runs still need.

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
agents to their own file access, their own execution, and MCP. The
model-facing surface is three code-mode tools from
`FoundationModelsMultitool`: `searchTools`, `runCode`, and `wait`. The
capability modules — `files`, `shell`, `mcp` — live inside the MultiTool
registry, and with the standalone `skills` tool they are the **full surface**
through which this agent touches the user's world. In-process capabilities are
the approved design, not an accepted risk. The confinement story stays ours:
`withFiles(root:additionalRoots:)` bounds `files`. `SeatbeltSandbox` bounds
`shell`. **There is no permission prompt and no policy layer** (§11.7).*

### 11.1 The catalog

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the one place
where we compose the tool surface. It builds one `MultiTool` through
Multitool's `Builder`. Each capability module gets one reserved config
section. To add a capability: decode its section, construct its values, and
add one builder line:

```swift
/// The tool catalog.
///
/// ══════════════════════════════════════════════════════════════════
///   ADD NEW CAPABILITIES HERE — and only here.
///   1. Decode the module's config section (§11.2).
///   2. Append its `with…()` call to `makeRegistry(context:)` below.
///   3. Add a row to the table in README.md § Tools.
///   Nothing else in this package needs to change.
/// ══════════════════════════════════════════════════════════════════
public enum ToolCatalog {
    public static func sessionSurface(context: CatalogContext) async throws -> SessionSurface
}
```

The function returns a `SessionSurface`: the composed tool array for
`makeSession(tools:)`, plus the `MCPServerPool` the session lifecycle shuts
down after the session sweep (§10.1, §11.5). **It is `async` because it must
be.** `withMCP(servers:)` is `async throws` (§2.5). A synchronous function
cannot call it.
`MultiTool.Registry.makeSessionTools(librarian:sampleGenerator:)` vends
**three** tools, in this mount order: `searchTools`, `runCode`, `wait`. In
direct mode it vends `runCode` and `wait`. **`wait` is mounted in both
modes.** The catalog appends the standalone `skills` tool (§14.2) to that
array. Router mounts `ElevatingTool` around each native
entry. `ToolInvoker` binds the ambient `ToolContext` around each `tools.*`
call (Multitool eventplan). We name our construction context
`CatalogContext`, because Router's `Hosting/` substrate owns the name
`ToolContext`. `CatalogContext` carries what each builder call needs: the
session working directory, the session's additional roots, the decoded config
section, **and the resolved profile**.

**The profile is load-bearing here, not a convenience.**
`makeSessionTools(librarian: RoutedLLM?, sampleGenerator: RoutedLLM? = nil)
throws -> [any Tool]` needs a librarian model, and the host passes
`profile.flash`. Therefore the catalog receives the resolved profile, not only
config values. Frontends can register their own capabilities through
`withCapability(_:)` before the build. Catalog entries also register
slash-command providers (§14.1, source 2). An entry can pair its capability with a
`SlashCommandProviding` conformer. The catalog feeds it into the session's
command registry. The direction rule is absolute: Multitool conforms to the
leaf's protocol. No code outside this package names this package's types.

### 11.2 The enable/disable rule

**Each built-in capability is on, unless the config sets it off. Absence
enables.** A user with no config file gets an agent with all capabilities,
each with its own defaults. Multitool's `Builder` keeps its modules off until
a `with…()` call opts them in. This layer makes that call for each enabled
module. The config decides which calls occur. One rule, five shapes:

| Config | Meaning |
|---|---|
| no `tools:` section | every built-in on, with defaults |
| `tools:` present, tool not mentioned | that tool on, with defaults |
| `shell: {}` / `shell:` (null) / `shell: true` | on, with defaults — explicit but redundant |
| `shell: {storeDirectory: …}` | on, body decoded as **that package's own option type** |
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

**Two source packages: `FoundationModelsMultitool` for the capability modules,
and `FoundationModelsSkills` for one standalone tool. The catalog composes
both:**

| Capability | Builder call | Blocked on | Config section |
|---|---|---|---|
| `files` | `withFiles(root:additionalRoots:readOnly:allowSymlinks:recordsChanges:)` — **shipped** | nothing | `files:` |
| `shell` | `withShell(storeDirectory:sandbox:outputChunkStream:)` — **shipped** | nothing | `shell:` |
| `mcp` | `withMCP(servers:)` — **shipped** | nothing; the ACP tunnel is unstable-gated (§11.5) | `mcp:` (plus ACP's per-session `mcpServers`) |
| skills → `/id` commands | `SkillsRegistry` as a `SlashCommandProviding` conformer — **shipped in Skills** | nothing | `skills:` |
| skills → model access | the standalone `skills` tool, appended to the tool array — **shipped in Skills** | nothing | `skills:` |

**Follow-ups — one `withCapability(_:)` line each, as each capability ships:**

| Capability | Source | Blocked on | Config section |
|---|---|---|---|
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | a `Capability` over `CodeContext` | nothing; first follow-up | `codeContext:` |
| `agents` — sub-agent delegation (start, check, send, cancel) | a `Capability` in Multitool — **not implemented yet**; a later iteration | the Multitool agents capability, which is plan-only upstream (§21) | `agents:` (reserved) |

**Agents are not implemented yet.** They arrive in a later iteration, as a
Multitool capability behind the code-mode surface. The model does not get a
stand-alone `agents` tool. It calls `runCode`, and the snippet calls
`tools.agents.*`. A sub-agent is a long-running background tool, so the
capability must mount `.background`, in the same way as `runCode` and the
`shell` commands: a start call hands back a `completionToken` at once, and the
model collects the result through `wait(completionToken, seconds)`, examines
it through `status()`, and ends it through `cancel()` (§11.4). Router's
background engine owns that run plane. This is also why the design fits the
one-identity rule in §1: the `completionToken` is the `toolCallId` that the
client sees, and it becomes `AgentSpawn.parentToolCallId` on the child
session. Each run is a Router session made through `makeSession(agentSpawn:)`.
It is never an ACP session (§4.2). The design source is
`../FoundationModelsAgents/plan.md`. That plan predates code mode: it describes
a fused `OperationTool` named `agents` over the removed
`FoundationModelsOperationTool` package, and the Multitool capability replaces
that shape. Until it ships: no `agents:` config section, no `withCapability`
line for it, and `agentSpawn: nil` at `session/new` (§7.1). When it ships,
add it here with one `withCapability(_:)` line (§11.1), and release it as a
user-visible roster change (§11.2).

**Skills is a standalone tool and a command provider. The two halves answer
different questions.** The `skills` tool is model access ("what can I do
here?", for the model). The `/id` commands are *explicit dispatch* ("do this
specific thing", for the user). One `SkillsRegistry` serves both halves.

**Skills is not a Multitool capability and is not a registry entry behind
`searchTools`.** It is a plain `FoundationModels.Tool` that the catalog
appends to the tool array. Neither package depends on the other (§1, §14.2).
**The design reason is this project's decision, not an upstream claim: a skill
loads in one request/response step.** Skills is deliberately not an async
code-mode capability here, because
loading a skill into context must stay short, and code mode is for
long-running asynchronous work.

**The `OperationTool` type is not gone.** Removing the standalone
`FoundationModelsOperationTool` package removed a package, not a type.
`OperationTool` lives at
`FoundationModelsExtras/Sources/Operations/OperationTool.swift:25`, ships as
Extras' `Operations` product
(`public struct OperationTool<Context: Sendable>: Tool`, with
`Arguments = GeneratedContent` and `Output = String`), and Skills is built on
it today. (The two integration gaps: §14.2.)

### 11.4 Confinement

- **`files`**: the files capability confines it to a **root set**: the session
  cwd plus its `additionalDirectories` (§7.2). `cwd` stays the special member
  (the base for relative paths). But a path in any root validates. Pass the
  set through `withFiles(root:additionalRoots:)`. **`PathGuard` is internal.
  Do not try to name it.** The verbs are `tools.files.read`, `.write`,
  `.edit`, `.patch`, `.glob`, `.grep`. Their argument and output structs are
  internal too: only `FilesCapability` is public. **Every output carries a
  `correction: String?`.** A corrective result is in-band. It is never thrown.
  Therefore the wire mapping (§11.6) must read `correction`, not an error.
- **`shell`**: **`SeatbeltSandbox` is the only gate** (§2.5, §11.7). Build its
  `Options(writableRoots:)` from the same root set, so writing and deleting
  stay inside the session's roots. **There is no policy, no denylist, no ask
  route and no remembered decision.** The stated limit stays: reads are free
  and the network is open, so the sandbox does not bound exfiltration. The
  verbs are `tools.shell.execute`, `tools.shell.getLines`,
  `tools.shell.grepHistory`. The capability's own `status()` and `cancel()`
  verbs are **removed**: Router's background engine owns the run plane. The
  MCP follow-up pseudo-tools `get_result`, `list_calls` and `cancel_call` are
  removed too, and the snippet globals `status()`, `wait()` and `cancel()`
  replace them.
- **`mcp`**: dynamic. The tools that it gives depend on what the servers
  advertise. Connection completes before `buildRegistry()` (§7.3). A late
  server, a reconnect, or a `tools/list_changed` starts a registry rebuild
  (`rebuildRegistry()` → `RegistryStaging.stage(_:)`). MultiTool applies the
  staged registry at `MultiTool.turnWillBegin()`. **An in-flight run keeps the
  registry that it started with.**

### 11.5 MCP wiring: two sources, two transports (+ one unstable), two sinks

**Sources**: the local `mcp:` config, and the client's per-session
`mcpServers`. Compose them per §7.3 (client servers have session scope, come
after config-derived servers, and never persist).

**Transports** (advertise them as `McpCapabilities` at `initialize`,
`capabilities.session.mcp`; nothing does that today):

- **stdio** → `StdioServerProcess(command:args:env:name:) throws`. The
  `McpServerStdio` fields map one to one, with one hard rule: **`command` must
  be an absolute path.** Resolve the client's command before you construct the
  process. The process has `respawn() async throws -> any Transport` and
  `shutdown() async`. Its
  env entries are `EnvVariable { name, value }`, and **env layers onto the
  inherited environment. It never replaces it.**
  `capabilities.session.mcp.stdio`.
- **http** → `HTTPClientTransport`. ACP's `headers` supply the auth.
  (Authorization stays the host's job, per the mcp capability's decision.)
  `capabilities.session.mcp.http`.
- v2 removed `sse` fully. There is no `McpServerSse`, and no third stable
  transport.

**The ACP tunnel is unstable-schema-only. Plan it. Gate it. Do not promise
it.** `mcp/connect` + `mcp/message` + `mcp/disconnect` exist only in
`acp-v2.meta.unstable.json`. No stable capability can ask for a tunnel. The
design, when it lands: the **client** hosts the server. The agent tunnels MCP
JSON-RPC over ACP. **`ACPTunnelTransport` goes in this package.** It is an
`MCP.Transport` conformance that needs ACP types. Multitool must
never depend on `FoundationModelsACP`. The transport plugs into the mcp
capability's transport factory. The client owns the processes. Thus `StdioServerProcess` is
not used. Two blocks exist: the wire package must generate the `mcp/*` payload
types (filed as `kdvsjmj` on its board), and the methods must graduate to
stable. Ship stdio + http first.

**Process lifecycle is the mcp capability's job, not ours.** It spawns and
owns the stdio subprocesses. Server subprocesses are infrastructure with
session lifetime — they are never runs, and they never get a
`completionToken` (eventplan). This package passes server entries to
`withMCP(servers:)`.

**The shapes we build against:**

- **`MCPServer` is an actor**:
  `MCPServer(name:version:clock:callTimeout:renderBudget:elicitationHandler:logger:)`,
  with `connect(via: any Transport)` and `connect(via: @escaping
  TransportFactory)` — each also taking a `BackoffPolicy` — plus
  `reconnect()`, `disconnect()`, `waitUntilReady()` and
  `call(name:arguments:)`. `MCPServerState` is `connecting` / `ready` /
  `disconnected` / `faulted(String)`.
- **Reconnects and pooling shipped.** `MCPServerPool` is an actor with
  `add(server:)`, `add(process:)`, `attach(attachment:)` and
  `shutdownAll()`. Reach it as `Builder.serverPool`.
- **`SurfaceRefresher(source:staging:servers:logger:)`** consumes each
  server's `catalogUpdates` stream and stages a new registry. It does NOT
  subscribe to `tools/list_changed` directly: the stream also fires when a
  connect reaches `.ready`, and when a connect fails after an earlier
  success. Therefore expect a rebuild on a reconnect, not only on a re-list.
  **It asserts in `deinit` if
  it is released while its watch task runs.** Therefore the host must call
  `stop()` on it, or attach it to the pool. Do not drop it.
- **Shutdown order matters**: sweep the sessions first, then call
  `MCPServerPool.shutdownAll()` (§10.1).
- **An MCP verb is a plain synchronous `Tool`. It does not background.** A
  transport drop throws a `LostRunError`, and the run settles `.lost` (§8.4).

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
  per-call record** from the mcp capability. They do not use its
  model-facing rendered string. That string is elided, intentionally.
- **`ToolAnnotations` → `ToolKind`**: the correct use of MCP's untrusted
  hints. A UI hint feeds a UI hint. It is never a gate.
- **`destructiveHint` / `openWorldHint` are UI hints only.** They gate
  nothing. There is no permission prompt in this agent (§11.7). Render them.
  Do not act on them.

The shared-outcome decision changes terminal status only. The
`ToolAnnotations` → `ToolKind` decision above is untouched.

### 11.6 Reporting: `tool_call_update`

v2 has no `tool_call` create. `tool_call_update` is an upsert. The first
update with a new `toolCallId` is the creation.

- **`status` defaults to `pending`** when a creating update omits it. A call
  that already runs must say `in_progress`. If not, the client shows it as
  queued.
- `ToolCallUpdate` requires only `toolCallId`. `title` SHOULD be on the first
  report.
- **Two content forms, one algebra.** `tool_call_content_chunk` appends one
  `ToolCallContent` item. A `tool_call_update` with `content` replaces the
  whole array. `content` omitted leaves it unchanged. Stream live output as
  chunks. Send the complete content in the settlement update, from the
  stored record, so the final replace converges a client that missed a
  chunk. Never send a chunk after the settlement update. `locations` is
  replaced as a whole array too.
- **The diff mapping trap**: ACP's `path` is absolute and **post-operation**.
  For `move` / `copy` (`DiffPathPairChange {oldPath, path}`), the files
  capability models
  the same data in the other direction. Map `FileChange.path → oldPath` and
  `FileChange.destinationPath → path`, for those two kinds only. For `add` /
  `delete` / `modify`, map `path → path` without change. A naive
  `path → path` map shows the pre-rename filename at each move, silently.
  (The files capability's shape is self-consistent. This is a translation
  note, not an upstream ask; `d7jwam5`.)
- `DiffChange` carries optional `fileType` / `mimeType`. Fill them where the
  tool knows them. They drive syntax highlighting in the client.
  `ToolCallLocation` requires `path`. `line` is optional (`GrepMatch` supplies
  both).
- `status`, `kind`, `title`, `rawInput`, and `rawOutput` all have
  `x-deserialize-default-on-error`. A bad field degrades. It does not fail the
  notification.

### 11.7 `session/request_permission` — we do not use it

**The decision is sandbox-only. This agent does not advertise and does not
send `session/request_permission`.** There is no permission mode, no
`permissions:` config section, no `policy` or `ask` setting, and no
remembered `allow_always` / `reject_always` store. Upstream deleted the shell
permission layer on 2026-08-24 (§2.5). We follow it.

**The reason:** a denylist over command text is bypassable. The sandbox is a
kernel boundary, and it does not care how a command is spelled. A prompt that
the user answers a hundred times a day is not a boundary either.

**`SeatbeltSandbox` is the only gate.** The host builds
`SeatbeltSandbox.Options(writableRoots:extraWritePaths:)` and passes the
sandbox to `withShell(sandbox:)`. `preflight` is `async throws` and runs a
canary before any command starts. A failed preflight means the command does
not run. There is no path from a failed preflight to an unconfined spawn.

**Never pass an empty `writableRoots`.** The initializer replaces an empty
list with the process working directory before it resolves the paths. So an
empty array does not mean "write nothing". It silently means "write wherever
this process happens to be running", which is the widest grant the type can
give and the opposite of the intent. Always pass the session root set, and
fail loudly if it is empty rather than handing an empty array through.

**The `sandbox:` config section (§2.4).** It replaces the deleted
`permissions:` section, and it holds one key:

- **`writableRoots` is not a config key.** It defaults to the session root set
  — the cwd plus the additional roots (§7.2). Configuration does not set it.
- **`extraWritePaths` is the only knob.** It comes from the `sandbox:`
  section. Use it for a build cache or a temporary directory outside the
  roots.
- **Build the options only through
  `SeatbeltSandbox.Options(writableRoots:extraWritePaths:)`.** That
  initializer runs `resolvedPath` over both lists. Never pass the output of
  `URL.resolvingSymlinksInPath()`. On macOS that call strips `/private` and
  gives the one path form that Seatbelt cannot match.

**The stated limit, recorded here so nobody assumes more:** the sandbox bounds
**writing and deleting only**. Reads are free and the network is open.
**Therefore the sandbox does not bound exfiltration.** Say this in the docs.

A client that asks for the permission capability gets "off", honestly (§1's
rule for a noun with no peer).

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

The mapping is `shell`'s user-visible payoff. The shell capability's
`commandID` (= the run's `correlationID` = its `completionToken`) →
`terminalId`. Incremental line streaming → `terminal_output_chunk` (base64 for
each chunk; byte-true, with no lossy text coercion). The stored record →
`TerminalOutput` (what a reconnecting client needs). Command exit →
`TerminalUpdate.exitStatus` (the "exited even when unknown" semantics agree
with a soft-deadline kill). The tool call sends a `Terminal` content
reference. The bytes ride the terminal stream.

**The precondition is satisfied. Raw bytes survive.** The shell capability
gives us these types:

| Type | What it carries |
|---|---|
| `ShellOutputChunkStream` | an `AsyncSequence` of `ShellOutputEvent { commandID, kind }`; pass it to `withShell(outputChunkStream:)` |
| `ShellRawOutput` | `{ bytes: [UInt8], binaryDetected: Bool, truncated: Bool, storedByteCount: Int }` |
| `ShellOutputSnapshot` | `{ stdout, stderr }`, read with `snapshot(for commandID:)` |

Map `ShellRawOutput.bytes` to `terminal_output_chunk` (base64, byte-true) and
`ShellOutputSnapshot` to `TerminalOutput` for a reconnecting client.

**But the package has no PTY, no ANSI parser and no terminal renderer.**
Terminal presentation is our layer. Plan for it here, not upstream.

**Sequence** (decided 2026-09-01, §8.4): the terminal stream is additive over
the usual tool-call content, and it is a follow-up. Day one, `shell` streams
live output as **`tool_call_content_chunk`** with a text `content` item per
`ShellOutputEvent.Kind.output(stream:bytes:)`, decoded as UTF-8 with
replacement; a `.gap(stream:droppedByteCount:)` becomes one chunk that names
the dropped byte count; `.completed` ends the run's chunks. The settlement
`tool_call_update` then carries the complete `content` from the stored record
(§11.6). When the terminal stream lands, `shell` moves its bytes to
`terminal_output_chunk` and the tool call carries a `terminal` reference;
`tool_call_content_chunk` stays for every other streaming source. Do not
design the shell tool's output path so that it discards raw bytes before the
wire.

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
credentials. The refusal is the files verb's own. Resolve the URI through the
`files` capability that `withFiles(root:additionalRoots:)` bounds (§7.2,
§11.4). A path outside the root set comes back refused **in band**: the files
verbs return their output's `correction: String?` field, and they do not
throw. Read that field and report the reason. Do not name `PathGuard`; it is
internal.

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

For the time when a planner lands, know this
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
3. **Skills**: the *data* lane, and it is **shipped, not plan-only**.
   `SkillsRegistry` (the `FoundationModelsSkills` package) finds and renders
   `SKILL.md` files, and it **already conforms to `SlashCommandProviding`**:
   `commands(workingDirectory:) async -> [SlashCommand]` and
   `commandUpdates: AsyncStream<[SlashCommand]>?`. The stream is `nil` when
   the registry was built with `watch: false`. One skill = one `/id` command.
   Each command carries `.prompt(template:)` with the skill's **raw,
   unrendered** body (see the render-fidelity warning in §14.2). Skill
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
- **We construct the stack. Skills takes what it gets** (§2.5). Build
  `SkillsRegistry(stack: DotfolderStack(name: "skills", …))`. The other
  initializers are `init(roots:)` and `init(layers:)`. **The derived trust
  differs**: `init(roots:)` treats **every** root as untrusted, while
  `init(stack:)` keeps each layer's `Layer.source`, from which the real trust
  follows. Use `init(stack:)`. **A `DotfolderStack.Layer` carries no trust
  tag.** It has exactly `source: Source` and `root: URL`. Trust is a
  `TemplateEngine` concept, and each consumer **derives** it from
  `Layer.source` on its own, because the source-to-trust mapping is a private
  helper and not public API. Extras derives it inside `LayeredYAMLDocument`.
  Skills derives its own equivalent inside its Stencil pass. The two mappings
  agree today, and nothing in the type system holds them together.
- **Preload feeds the system prompt.** `registry.preloadedBodies()` renders
  the `preload: true` skills through all three render passes and returns the
  result as **one joined `String`**. It is not raw text, and it is not a
  collection. Fold that one string into the session `Instructions` (§3.1).
- **Trust**: both layers are untrusted. Skill markdown renders under the
  untrusted template rules.
- **The `skills:` config section stays in the `<name>` stack.** The content is
  shared. The behavior is per-agent. `skills: false` stops discovery for this
  agent. It does not touch a different person's library.

**Gap 1: render fidelity. Extras' `SlashCommand.Body` already has the third
case, and it closes the gap.** `SlashCommand.Body` ships **three** cases:
`case prompt(template: String)`, `case action(@Sendable (Invocation) ->
AsyncThrowingStream<String, Error>)`, and
`case rendered(@Sendable (Invocation) async throws -> String)`. Extras
documents `.rendered` as the escape hatch for exactly this problem: a provider
whose substitution model does not match the Stencil engine. The conformer
renders. The dispatcher gives the result to the model, as it does for
`.prompt`. **Therefore the dispatcher prefers a `.rendered` body wherever a
provider offers one.** The trust boundary stays: only linked Swift can
construct a closure.

**What remains is a Skills-side adoption.** `SkillsRegistry` vends commands
today, and each one still carries `.prompt(template:)` with the skill's
**raw, unrendered** body. **A host that runs that template through the harness
engine gets only that engine's rendering.** Skills' own passes never run: the
`$`-argument substitution and the `` !`shell` `` injection. Therefore `$0`,
`$ARGUMENTS` and backtick-shell syntax pass through inert, and the user sees
the literal text. **Until Skills adopts `.rendered`, our dispatcher routes
skill commands through `registry.call(id:arguments:)`**, as a special case,
for full fidelity. The adoption is filed as **`c2pad49`** (§21).

**Visibility is per-skill front matter. Map it to the two surfaces:**

| Front matter | In the `/` menu | Searchable by the model | In `Instructions` |
|---|---|---|---|
| *(default)* | yes | yes | no |
| `disable-model-invocation: true` | yes | **no** | no |
| `user-invocable: false` | **no** | yes | no |
| `preload: true` | yes | yes | **yes** |

**Gap 2: ACP flattens the parameter model.** Skills has a real model
(`SkillParameter { name, position, required, variadic, placeholder }` +
`acceptsTrailingArguments`). ACP's `AvailableCommandInput` is a single
`{type: "text", hint: String}`. **Pass Skills' `argument-hint:` string
through, verbatim, as the hint.** It is already in display syntax
(`<env> [region] [flags...]`). Thus the lossy step loses nothing that a human
reader needs. Structured parameter prompting is an `_meta` extension, if a
client wants it.

**Both halves are shipped, so ship them together** (§11.3). One
`SkillsRegistry` serves the `/id` commands and the `skills` tool. Construct
the tool with
`SkillsTool.make(registry:session:embedder:followReloads:visibilityPredicate:)
async throws -> OperationTool<SkillsToolContext>`. There is an overload that
takes a session factory closure
`@escaping @Sendable (String) -> any AgentSession`, and one with **no
`session:` at all** — keyword retrieval only, with no model and no tokens.
Use the last one when the config turns model access off.

The model-facing tool name is `"skills"`. Its description is "Search, list,
and use skills from the local skill library." **It is one fused tool with six
operations behind an `op` discriminator**: `search skill`, `list skill`,
`use skill`, `list resource`, `read resource`, `run script`.

Skills' own package facts: the product is `FoundationModelsSkills`, from
`git@github.com:swissarmyhammer/FoundationModelsSkills.git`, platform
`.macOS("27.0")`, with dependencies on FoundationModelsExtras (products
`FoundationModelsExtras`, `Operations`, `OperationsCLI`),
FoundationModelsMetadataRegistry, and Yams. It does `@_exported import` of
Extras and MetadataRegistry. Therefore one import of `FoundationModelsSkills`
reaches `DotfolderStack`, `TemplateEngine`, `SlashCommand`, and
`SlashCommandProviding` from Extras. It also reaches `AgentSession` and the
`LanguageModelSession: AgentSession` conformance, but **those two are not
Extras**. They live in **FoundationModelsRanker**. MetadataRegistry re-exports
Ranker, and Skills re-exports MetadataRegistry, so the names arrive through
that chain.

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

**The profile shapes, exactly:**

- `ProfileDefinition(name:description:standard:flash:embedding:context:)`.
  **`standard`, `flash` and `embedding` are `[ModelRef]` candidate lists, not
  single values.** `description` is required. `context: Int?` defaults to
  8192, and `nil` opts into ladder derivation from each candidate's native
  max context. `ModelSlot` is `standard` / `flash` / `embedding`.
- **Trap: `ModelRef`'s `repo`, `revision`, `init(repo:revision:)` and
  `init(_ string:)` are all internal.** From outside, build a `ModelRef` only
  from a string literal or by decoding, and read it back only as
  `stringValue`. The separator is `@`, as in `"org/repo@rev"`. Therefore the
  `select` option's values are `stringValue` strings.
- `LanguageModelProfile` exposes `definitionName`, `standard`, `flash`,
  `embedding` and `release()`. Its init is `package`. Therefore
  `Router.resolve(profile:reporting:)` is the only way to get one. Residency
  is pooled and reference-counted.
- **`ResolutionFailure` — the error that `resolve` throws when no trio fits —
  is internal, so we cannot catch it by type.** The same is true of
  `SessionReentryError` and of the restoration and reconstruction errors: they
  are internal, and we get `any Error`. Therefore report a resolution failure
  by its message, and never by a `catch` on a case.
- **Five Router error types are public, and we catch these by type:**
  `GuidedRequestError`, `GenerationError`, `ToolMountError`,
  `DiscoveryPrimingFailure`, and the protocol `LostRunError`. `LostRunError`
  matters to us: a tool error that conforms to it makes the run settle
  `.lost` (§11.6).

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
- **The `set` request's value is tagged by `type`.** A select option is set
  with `type: "id"` and the value id; a boolean with `type: "boolean"` and
  `true`/`false`. The wire's `SetSessionConfigOptionRequest` value is
  `.id(SessionConfigValueId)`, `.boolean(Bool)` or `.other(String,
  JSONValue)` for an unknown tag. A `.other` value, or a value whose type
  does not match the option, is invalid params (§10.1's error values); the
  state does not change and no push goes out.
- `SessionConfigOption` requires only `configId` + `name`. The `select` /
  `boolean` / `other` variants supply `currentValue` (and `options`). Grouping
  is a wrapper (`SessionConfigSelectGroup{groupId, name, options}`), not a
  field on options. We ship without groups. `category` is UX-only ("MUST NOT
  be required for correctness").
- **Each option MUST have a default.** Then a client that ignores config
  options gets a session that operates.

## 16. Elicitation

**This package owns elicitation.** It is the only layer with a live two-way
channel to a thing that has a user. Multitool and Router own no UI.

**`ElicitationCoordinator` and `MCPElicitationTool` no longer exist. Do not
plan against them.** Multitool's seam is now one closure on the server:
`MCPServer.init(elicitationHandler: ElicitationHandler?)`, where
`public typealias ElicitationHandler = @Sendable (ElicitationRequest) async ->
ElicitationResponse`. Three answerers run in a fixed order:

1. the `ToolContext` of the calling run, through Router's `SessionMailbox`;
2. else the host's `elicitationHandler`;
3. else `cancel` to the server.

**Upstream states: "Router wins when present, so a Router host never sets the
handler." We are a Router host.** Therefore our seam is Router's, not
Multitool's:

- `RoutedSession.respond(elicitationId:response:) -> ElicitationAnswerDelivery`
- `RoutedSession.complete(elicitationId:) -> ElicitationCompletionDelivery`

Build the ACP relay on those two calls. Leave
`MCPServer(elicitationHandler:)` nil.

**Elicitation is not the permission system.** Upstream says so in as many
words, and §11.7 says the same from our side: there is no permission prompt
in this agent. An elicitation asks the user a question that a tool needs
answered. It does not authorize anything.

**It is a relay, not a translation.** MCP and ACP elicitation are almost
isomorphic:

| MCP (swift-sdk) | ACP (`elicitation/*` — stable v2, generated in the wire package) |
|---|---|
| `CreateElicitation` `.form(FormParameters{message, mode?, requestedSchema})` | `elicitation/create`, `mode: "form"`, `message`, `requestedSchema` |
| `.url(URLParameters{message, mode, url, elicitationId})` | `mode: "url"`, `message`, `url`, `elicitationId` |
| `Result.Action { accept, decline, cancel }` | `action: accept \| decline \| cancel` (+ optional `content`) |
| `notifications/elicitation/complete { elicitationId }` | `elicitation/complete { elicitationId }` (agent → client) |

Both directions of MCP elicitation reach the same seam: a server that stops in
a tool call, and a tool that asks the user through the run's `ToolContext`.

**Requirements:**

- **Scope each request**: `sessionId` plus `toolCallId` (the MCP call handle
  maps to it; then the client can show *which* tool call asks, including a
  detached long call that would otherwise ask with no context); or a
  `requestId` for interactions outside a session.
- **Gate on capability. Degrade honestly. The gate is the real
  `capabilities.elicitation` field, not `_meta`.** Stable v2's
  `ClientCapabilities` carries `elicitation: ElicitationCapabilities?` with
  `form` and `url` sub-objects (§5). Absent or `null` means unsupported, at
  each level. Check the mode the tool needs. When that mode is unsupported,
  return MCP **`decline` with a clear reason**. There is no permission method
  to fall back to (§11.7), and an options-based method could not carry a
  `requestedSchema` anyway.
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

**The wire is ready. The Router request side is not.** The wire package
vendored `schema-v2.0.0-alpha.3` and generated the types (`7kgq5dw` and
`enzjy0q` are done, §21). `AgentSideConnection.createElicitation(_
params: CreateElicitationRequest) async throws -> CreateElicitationResponse`
sends the request, and `elicitationComplete(_:)` sends the URL-mode
completion. `CreateElicitationRequest` is `{ message, mode }`, where `mode`
is the flattened form/url payload. `CreateElicitationResponse` is a
`JSONValue` typealias today, so the relay decodes `action` and `content`
itself. The client sibling's M7 is done too, so a tier-2 test drives both
ends with `SwiftUIACPClient.acceptElicitation(_:content:)` and
`declineElicitation(_:)` (§20.1).

**Router gives a host no public live signal that an elicitation is
pending.** `ToolContext.elicit(_:)` posts an `OperationEvent` with `kind:
.elicitation` to the session outbox. But `SessionEvent` has no case for it,
`SessionMailbox.pendingElicitationIds()` and `SessionOutbox.pending()` are
internal (Router's audit "Close the public surface to what a host actually
calls" made them so), and `TranscriptEvent.operationEvents` is a recorded
read that arrives at the next turn drain, not live. Router's own tests reach
the internal mailbox. The answer side is public
(`respond(elicitationId:response:)`, `complete(elicitationId:)`); the request
side is not. **This is an upstream ask** (§21): a `SessionEvent` case on
`streamSessionEvents()` that carries the `.elicitation` `OperationEvent`, or
a public `RoutedSession.pendingElicitations()` read with a wakeup. Do not
poll the transcript. The relay is board task `2z6qtqy`, and it waits on that
ask. The interim stays: our Router-side relay declines each elicitation with
a clear reason: "this host cannot ask you questions yet". That is honest, and
it keeps the MCP built-in unblocked.

## 17. Transports

**Framing** (these are protocol MUSTs, not house style): messages are UTF-8
JSON-RPC. `\n` divides them. A message MUST NOT contain a newline. There is no
content-length header. The agent **MUST NOT write non-ACP content to stdout**.
The tier-3 integration test (§20.1) asserts this MUST. stderr is free
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
The shell capability captures child output. It does not let children
inherit. Tier 3
(§20.1) proves this, end to end.

## 18. Extensibility

- **Each extension goes in `_meta`, never adjacent to it.** Implementations
  MUST NOT add custom fields at the root level of spec-defined types. All root
  names are reserved for future protocol versions. Elicitation is **not** an
  extension any more: its gate is the real `capabilities.elicitation` field
  (§5, §16). `_meta` covers each other extension that we think of. Root-level
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
| 0 — unit | — | — | — | no | do the tools work in isolation *(done upstream: Multitool's capability suites — files, shell, mcp — and Router's 624 tests)* |
| 1 — golden conformance | scripted | `SwiftUIACPClient`, in-process | fake | no | is the wire shape right — ordering, upserts, replay |
| 2 — tool integration | scripted | `SwiftUIACPClient`, in-process | **real** | no | do real tools work through the real conformance |
| 3 — stdio contract | scripted | `SwiftUIACPClient` over `AgentProcess` | real | yes | does framing survive a real process boundary |
| 4 — eval | **real** | `SwiftUIACPClient`, in-process | real | yes | does a local model, driven over ACP end to end, *choose* to use tools, and succeed |

**The client driver is the sibling `FoundationModelsACPClient`. Do not write
a test client.** The package shipped: its board shows M0–M7 done, and its
README documents the shape below. `SwiftUIACPClient` is the `Client`
conformance. It is `@MainActor` and `@Observable`, it does not import SwiftUI,
and a headless test can use it. `connect(over:logger:)` takes any
`ACPTransport` and returns the `ClientSideConnection` that drives the agent.
One `ACPSessionState` per session holds the projection: the ordered
`entries`, `toolCalls` keyed by `toolCallId`, `turnState`, `lastStopReason`,
`availableCommands`, `configOptions`, `title`, `updatedAt` and `usage`.
**That state is the primary assertion surface.** It is the same projection
that the Mac app binds to. A test that passes against it proves what the app
shows.

```swift
let (clientEnd, agentEnd) = InMemoryTransport.pair()
let agentConnection = await AgentSideConnection(stream: agentEnd) { _ in agent }
let client = SwiftUIACPClient(coalescingCadence: cadence, clock: testClock)
let connection = await client.connect(over: clientEnd)
// drive:  connection.initialize(_:) → connection.newSession(_:) → connection.prompt(_:)
// assert: client.session(for: id).turnState, .toolCalls, .entries — after flushPendingChunks()
```

Each tier above tier 0 uses this same wiring. The rules:

- **Inject the clock.** The client coalesces chunks on a cadence. A test that
  asserts text must call `flushPendingChunks()` or step the injected clock.
  Never sleep.
- **Arrival order is not in the state.** The container is a projection.
  `turnState` is a scalar and keeps no history. A proof that asserts order —
  the turn order (§8.1), cancellation (§8.6), replay upserts (§7.4) — needs
  the raw notification sequence. For those, the harness wraps the client in
  a ten-line forwarding recorder: it appends each `UpdateSessionNotification`
  to an `UpdateCollector`, then forwards it to
  `SwiftUIACPClient.sessionUpdate(_:)`. Build that path with
  `ClientSideConnection(stream: clientEnd) { _ in recorder }`, because
  `connect(over:)` binds the client itself. Both views see one stream, so a
  test can assert order on the collector and final state on the container.
- **`requestPermission` is pending state on the client.** We never send it
  (§11.7). A test asserts that `pendingPermissionRequests` stays empty.
- **Tier 3 spawns through `AgentProcess(command:arguments:)`.** It spawns the
  built `acp-agent` in its own process group and vends `transport`. `command`
  must be an absolute path. Hand the transport to `connect(over:)`. Teardown
  is proven by `processIdentifier == nil` after `shutdown()`; on transport
  teardown the child is group-killed and reaped. For the framing MUSTs (§17),
  wrap `agent.transport` in a tap that records the raw inbound bytes, and
  assert that each line parses as JSON-RPC and holds no interior newline. The
  client package wraps a transport the same way for its disconnect signal.
- **Dependency direction.** The test target and the `Examples/` executables
  depend on `FoundationModelsACPClient`. The library target never does. The
  client depends on the wire and Extras only, never on this package, so no
  cycle is possible (§1).

**Tier 2 is the tier that answers the question.** A real `ToolCatalog`, a
real `MultiTool` with the files and shell capabilities, a real
`RoutedACPAgent`, a real `session/new(cwd)`
against a temp directory — with a scripted *model*: inject a `ModelLoader`
whose `LoadedLLMContainer.makeSession` returns a `LanguageModelSessionBackend`
that sends a known tool call. (Router's own `ScriptedOverflowBackend` proves
the pattern. No upstream change is necessary.) There is no MLX, no download,
and no Apple-silicon gate. It runs in CI at each commit. Only tier 2 proves
these:

1. **Composition**: `ToolCatalog` constructs each tool with the correct
   `CatalogContext` (§11.1 — Router owns the name `ToolContext`): the root set
   from `cwd` + `additionalDirectories`, that tool's decoded config section,
   and the resolved profile.
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

**MCP gets tier-2 coverage free. The test support is shipped** (`4egfvw3` is
done). Multitool ships two products: **`MCPTestServer`** (a library) and
**`mcp-test-server`** (an executable). (`MCPTestServerCLI` is the old name and
is gone. **`ScriptedServer` still exists**, as a `public actor` inside the
`MCPTestServer` library, with its own self-test suite — use it to script a
server's answers.) Spawn a real server
process. List its tools. Call one. Confirm that the `tool_call_update`
correlation holds.

**The scripted-model seam is real, and Router ships test support.** Inject a
`ModelLoader`. `LoadedLLMContainer` gives
`makeSession(instructions:)`, `(instructions:tools:)`, `(transcript:)` and
`(transcript:tools:)`. A fake conforms to `LanguageModelSessionBackend`, whose
required members are `respond(to:maxTokens:)`,
`streamResponse(to:maxTokens:)`, `respond(to:following:maxTokens:)`,
`makeFork()`, `transcriptEntries()` and `usageTokenCounts()`. Router also
ships the products `FoundationModelsRouterTestSupport`,
`FoundationModelsRouterRealModelSupport` and
`FoundationModelsRouterEvalSupport`.

**Trap: some Router types have no public init, so a fake cannot construct
them**: `TurnOutcome`, `ToolCallEntry`, `BackgroundRun`, `ToolContext`,
`TranscriptEvent` and `TranscriptEvent.Partial`. `SessionSidecar` is the one
exception: its memberwise init is internal, but `init(from decoder:)` is
public, so a test can decode a `session.json` it already located — and then
read no field from it. **No
shipped `TranscriptRecorder` is reachable either** (`.jsonl`, `.inMemory` and
`.none` are internal, §4.6). Therefore a test cannot build a recording
fixture. Assert on the filesystem and on the wire, not on a constructed Router
value.

**Tiers 3 and 4 live in the nested `IntegrationTests` package, and stay
small.** That package is the whole selection: `swift test` at the root never
sees them, `swift test --package-path IntegrationTests` runs them, and the
shared CI workflow's integration job runs them at each commit. No environment
variable selects a test. Tier 3 exists for the one thing
that tier 2 cannot see: real process boundaries. stdout carries only ndJSON
while `shell` runs subprocesses that write to *their* stdout. And no message
contains a newline. (Both are protocol MUSTs, §17.) Tier 4 is §20.3.

### 20.2 Examples: `acp-agent` (the server + the tier-3 fixture) and `acp-print` (the client driver)

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

**`Examples/acp-print` — the client-server example.** The second example is a
one-shot prompt CLI, in the shape of `claude --print`: send one prompt, run
the turn to completion, print the answer, exit. It is the interop proof for
the two role packages: the sibling **`FoundationModelsACPClient`** (the
Client role) drives this package's server example across a real process
boundary. Nothing goes through a private back door — every byte crosses ACP.

```swift
// 1. spawn Examples/acp-agent over stdio; the client package owns and reaps the process
// 2. initialize → session/new(cwd) → session/prompt
// 3. stream the turn's agent_message_chunk text to stdout; exit at the stop reason
```

(The shapes are illustrative. The client plan owns the API; its container is
headless-usable by design.) The rules:

- `acp-print <prompt>` takes one positional prompt argument, and nothing
  else. The no-second-product rule of `acp-agent` applies here too: no
  flag surface, no rendering options, no config wizardry.
- **stdout carries only the answer text** (the `agent_message_chunk`
  stream). Logs and the stop reason go to stderr. The exit code is 0 for
  `end_turn`, and nonzero for `refusal`, `cancelled`, or an error.
- The client package spawns and owns the `acp-agent` subprocess, with its
  process-group and reaping obligations (client plan, "Transports"). The
  `acp-print` target links only `FoundationModelsACPClient` and the wire —
  never this package's library. A back-door import would break the proof.
- An end-to-end test in the nested `IntegrationTests` package (beside tier 3)
  runs `acp-print` as a subprocess and asserts: exit code 0, stdout is only
  the answer text, and no agent process outlives the run.

**The upstream gate is cleared.** `FoundationModelsACPClient` shipped; its
board shows M0–M7 done (§21). The shapes above are real: `AgentProcess`
spawns the agent in its own process group and vends `transport`;
`SwiftUIACPClient.connect(over:)` returns the connection;
`client.session(for:)` carries the streamed `entries`. Build `acp-agent`
first, because `acp-print` spawns it. The same client package is the driver
for every integration tier (§20.1), so `acp-print` and the tier-3 test share
one spawn-and-connect path.

### 20.3 Evaluations — `PythonCLIEvaluation`

The end-to-end coding eval belongs to the layer that composes the roster.
(Router keeps its compaction eval over sample tools.) The eval drives real
`files` + `shell` through a real multi-turn build task, on Apple's Evaluations
framework (swift-testing native). It needs Apple silicon + real models +
network, so it lives in the nested `IntegrationTests` package:

1. **Subject**: `subject(from sample:)` makes a fresh temp workspace (the
   session's `workingDirectory` and the tools' confinement root). It wires
   recording to a temp location. It constructs the composed agent with real
   `files`/`shell` and the coding instructions. **It drives the agent over
   ACP, end to end** (decided 2026-09-01): `InMemoryTransport.pair()`, an
   `AgentSideConnection` around the real `RoutedACPAgent`,
   `SwiftUIACPClient.connect(over:)` (§20.1), then `initialize` →
   `session/new(workspace)` → `session/prompt`, and it waits for
   `turnState == .idle`. It never calls the Router session directly.
   "Working" means a Client can drive the Agent, so the one tier with a real
   local model proves the same path that the Mac app and an editor use. It
   returns the workspace path + the transcript + the `ACPSessionState` + the
   recorder's notification list + the run stats.
2. **Dataset**: an `ArrayLoader` of `ModelSample`s. Each is a variant of
   "build a small Python CLI" (`pyproject.toml`, a third-party package such as
   `click`, the CLI, pytest tests, a project-local venv, pytest green, then
   run it). `expected` carries the fixed input/output pair. Start with 20–30
   hand-written samples, per Apple's guidance. Scale later with
   `SampleGenerator`.
3. **Evaluators: mechanical, and confirmed outside the agent.** They do not
   trust the transcript's claims. One `Metric` each: `PytestGreen` (runs
   pytest again in the venv; exit 0), `CLIRuns` (runs the CLI against
   `expected` and checks the output), `FilesPresent`, `ToolTraffic` (two
   readings that must agree: the transcript's operation events show
   `tools.files.*` and `tools.shell.execute` under `runCode`, and the wire
   shows the same — `ACPSessionState.toolCalls` holds completed `runCode`
   calls and the recorder holds `tool_call_content_chunk` updates for the
   shell steps, §8.4; tool traffic that never reached the wire is a
   projection defect).
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
| — | FoundationModelsMultitool | the consolidation itself: the shell, files and mcp capabilities are in, and `searchTools` + `runCode` + `wait` is the model-facing surface (§11.1) | **landed** 2026-08-24..27 |
| — | FoundationModelsMultitool (shell capability) | the shell permission layer is **deleted**; `SeatbeltSandbox` is the only gate (§2.5, §11.7) | **landed** 2026-08-24 — an upstream decision, not an ask |
| `c2pad49` | FoundationModelsSkills | adopt Extras' `.rendered` `SlashCommand.Body` case in Skills' `SlashCommandProviding` conformance, in place of `.prompt(template:)` with raw text (§14.2) | **the Extras half is done** — `.rendered` ships; the Skills adoption is **open**, and until it lands we dispatch skill commands through `registry.call(id:arguments:)` |
| `939nnzx` | FoundationModelsMultitool (files capability) | multi-root confinement through `withFiles(root:additionalRoots:)` (§7.2) | **done** |
| `4egfvw3` | FoundationModelsMultitool (mcp capability) | tier-2 MCP coverage through the `MCPTestServer` library and the `mcp-test-server` executable (§20.1) | **done** |
| — | FoundationModelsMultitool (agents capability) | sub-agent delegation as a code-mode **background** capability, reached through `runCode` → `tools.agents.*` and collected with `wait` (§11.3, §4.2); the design source is `../FoundationModelsAgents/plan.md`, which predates code mode | **plan-only** — not implemented; a later iteration. Nothing in this iteration waits on it: `agentSpawn: nil` at `session/new` |
| — | FoundationModelsRouter | a **public restore entry point feeding `session/resume`** (§4.6, §7.4) — `restoreSessionTree` and the tree types are internal, and the only public read is `TranscriptEvent.merged(under:)` | **open** — asked 2026-08-31, decision pending; do **not** reimplement restore against `transcript.jsonl` in the meantime |
| `7kgq5dw` → `enzjy0q` | FoundationModelsACP | schema re-vendor to `schema-v2.0.0-alpha.3` (elicitation stable), generated `elicitation/*` types, `ClientCapabilities.elicitation`, and the `createElicitation` / `elicitationComplete` entry points on both connections (§16) | **done** — verified 2026-09-01 |
| — | FoundationModelsRouter | a **public live signal for a pending elicitation** (§16): a `SessionEvent` case on `streamSessionEvents()` that carries the `.elicitation` `OperationEvent`, or a public `RoutedSession.pendingElicitations()` read with a wakeup. Today the answer side is public and the request side is not: `SessionMailbox.pendingElicitationIds()` and `SessionOutbox.pending()` are internal, and `TranscriptEvent.operationEvents` is a recorded read | **open** — to file; the relay (board `2z6qtqy`) waits on it, and the interim declines with a reason |
| `kdvsjmj` | FoundationModelsACP | `mcp/*` tunnel payload types (§11.5) | **closed without code** — verified 2026-09-01: `mcp/connect`, `mcp/message` and `mcp/disconnect` are still only routing names in `acp-v2.meta.unstable.json`, the published v2 pages name only `stdio` and `http`, and the wire task was closed by decision. Re-file when upstream stabilizes `mcp/*`. Our stance is unchanged: do not build the tunnel |
| — | FoundationModelsACPClient | the Client-role container (`SwiftUIACPClient`, `ACPSessionState`) plus the stdio transport with agent-process ownership (`AgentProcess`) — the client driver for every integration tier (§20.1) and for `Examples/acp-print` (§20.2) | **shipped** — M0–M7 done on its board, verified 2026-09-01; our test target depends on it, the library never does |
| `ke41yth` | FoundationModelsRouter | per-session recording root, flat `<root>/<sessionId>/` layout (§4.1) | **landed** |
| `kh01tv2` | FoundationModelsRouter | pooled, reference-counted model residency → per-project profiles (§7.1) | **landed** |
| — | FoundationModelsRouter | turn cancellation that reaches the model call: `cancelCurrentTurn()`, `cancelPrompt(id:)`, `ToolContext.cancel(completionToken:)` (§8.6) | **landed** — an in-flight MCP call still cannot be forced to stop |
| M1–M3, M5 | FoundationModelsSkills | the `/id` command half: `SkillsRegistry` conforms to `SlashCommandProviding` (§14.2) | **shipped** |
| M4 | FoundationModelsSkills | model access: the standalone `skills` tool, appended to the tool array (§11.3) | **shipped** |
| `d7jwam5` | FoundationModelsMultitool (files capability) | *note, not an ask*: rename/copy path mapping is a translation here (§11.6) | — |
| `1ad4ydw` | FoundationModelsExtras | the `OperationOutcome` terminal vocabulary on the `OperationEvent` envelope; Router re-exports it in `Hosting/OperationVocabulary.swift` — it feeds the one total status mapping that **we** own (§8.4, §11.5) | **landed** |
