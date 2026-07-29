# Plan: FoundationModelsACPAgent — the composed agent over the Router runtime

> The wire and the composition are separate packages: sibling
> [`../FoundationModelsACP`](../FoundationModelsACP/plan.md) is the pure,
> zero-dependency ACP wire (generated types, role protocols, connections,
> ndJSON); **this package is the agent** — it layers over
> **FoundationModelsRouter, the family runtime**, and adds slash-command
> support and configuration. Router sessions are the loop — self-folding
> (`makeSession(budget:compactionPrompt:)`), token-metered, event-streaming
> with correlation ids, recorded — and everything the runtime deliberately
> refuses to own lives here: file I/O, dotfolders, command registries, the
> roster, and the `Agent` conformance, named **`RoutedACPAgent`**.

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
                    │  RoutedACPAgent: the Agent conformance (§9.1)
                    ▼
   FoundationModelsACP (the wire: types, role protocols, connections — zero deps)
                    ▼
   FoundationModelsRouter — the runtime: models, sessions (self-folding,
                    │      token-metered, event-streaming, recorded), restore
                    ▼
   FoundationModelsExtras (stack, templating, SlashCommand, AgentsMd, LayeredYAMLDocument)
```

Dependencies: the ACP wire, Router, Extras, and — **day one, not eventually** —
the three sibling tool packages that make up the built-in roster:
**`FoundationModelsFileTool`** (`files`), **`FoundationModelsShelltool`**
(`shell`), and **`FoundationModelsMCP`** (`mcp`). See §7.1/§7.3; later roster
entries (code-context, multitool, skills, agents) are additive. Naming tool
packages is *this* package's job precisely because the runtime may not: nothing
cycles, since no tool package (and not the agents tool) ever depends on it.

The composition, end to end:

```
config  (dotfolder stack, §4)
  → ProfileDefinition → Router.resolve → resident profile
  → tools         (roster §7: config sections → constructed, confined tools)
  → instructions  (Instructions.md §6.0 + AGENTS.md §6.1)
  → per session:  router.makeSession(workingDirectory:tools:instructions:
                    budget:compactionPrompt:)   ← the self-folding runtime session
  → RoutedACPAgent(name:router:configuration:commands:)  ← §9.1; `name` is the
                    dotfolder name the frontend chose (§4), + registry §6.2
```

## Decisions

- **This package is the composition layer** — supersedes "the product layer
  awaits a home" and the interim ideas of a raw adapter directly over
  Router (commands and config had no source there) and of housing the
  composition inside the wire package (split out: the wire's consumers
  shouldn't drag in MLX, Yams, Stencil, and tool packages to decode a
  `SessionUpdate`). The noun test lands three ways: session storage/restore
  nouns and turn/loop nouns are Router's (the runtime, post-collapse), and
  commands + configuration + the conformance are this package's. Because the
  conformance composes Router's self-folding sessions, every loop behavior
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
  (`skills/<id>/SKILL.md`, via FoundationModelsSkills) load here as
  `.prompt`-only; `.action` requires linked Swift — the trust boundary
  travels intact. **Skills is the fourth day-one package** (§7.1), and it lands
  in two halves with different readiness: the *slash-command* half is day one,
  the *model-facing tool* half is a follow-up.
- **Configuration is this package's** (§4): the dotfolder name, the
  `AgentConfiguration` schema (`profile` with standard/flash/embedding
  slots, `tools` built-in + `mcp`, `recording`, `transcripts`, `compaction`
  — note **no `instructions` section**: the system prompt is a markdown file,
  §6.0), defaults in code plus `/config export` (§4), template-first
  rendering, and the mapping onto Router types. Router never sees any of
  it — sessions receive values.
- **Loading is Extras'.** `LayeredYAMLDocument` (Extras plan §11) loads →
  renders (trusted defaults, untrusted user/project) → merges with the
  family's one rule → returns a value tree with per-key source tracking;
  this package decodes it via `Codable`.
- **Three sibling packages ship as built-in tools, day one:**
  **`FoundationModelsFileTool`** (`files:`), **`FoundationModelsShelltool`**
  (`shell:`), and **`FoundationModelsMCP`** (`mcp:`). These are not optional
  extras and not follow-ups — they are declared `Package.swift` dependencies
  of this package, linked into the default roster, and enumerated in
  `ToolCatalog.builtin(context:)` (§7.1). They are also, after ACP v2 removed
  `fs/*` and `terminal/*` from the client side (§8.6), *the entire surface by
  which this agent reaches the user's world*: read/write a file, run a
  command, or call an MCP server. Anything else is a later roster addition
  (`codeContext:`, `multitool:`, `skills:`, `agents:` — §7.3).
- **The built-in roster is linked packages under well-known names, and it is on
  by default.** One reserved config section per tool — the three above, then the
  follow-ups. **Absence enables**: no `tools:` section at all, or a `tools:`
  section that simply doesn't mention a tool, means that tool is constructed with
  its own defaults. A section is written only to *configure* a tool (the body
  decodes as **that package's own option type**) or to *disable* one
  (`name: false`). *(Reversed 2026-07-28 from "presence enables," which had the
  fatal property that a user with no config file got an agent with no tools — the
  exact opposite of the works-out-of-the-box promise the defaults layer exists to
  keep.)* Unknown top-level sections warn; MCP is additionally the escape hatch
  for tools we don't link. This is the pre-pivot `ToolCatalog` "add tools here and
  only here" location, relocated to the one package allowed to name tool
  packages.
- **MCP transport is FoundationModelsMCP's job, not ours.** Config `mcp:`
  entries carry either `command` (+args/env — the MCP package spawns and
  owns the stdio subprocess) or `url` (http/s client connect); this package
  passes the entry to `MCPToolProvider` and receives `[any Tool]`. Process
  lifecycle, reconnects, and pooling across sessions are upstream asks on
  FoundationModelsMCP.

---

> The sections below carry legacy numbering (§4–§10.1) — renumber in a later
> editing pass. `§9.2` references point at the wire spec
> (`../FoundationModelsACP/plan.md`); `§8` references point at Router's
> board; `TranscriptStore` is this package's browse/location type (task
> ax6sdnt).

## 4. Configuration

### The pluggable dotfolder

#### `<name>` — where it comes from, and what it controls

**`<name>` is a construction parameter of this package's agent, supplied by the
frontend.** It is a bare word with no leading dot (`"coding"`, `"acme"`), and it is
not baked into any layer below this one — Router, the wire, and the tool packages
never see it. Two frontends that pass the same name share configuration and
transcripts; two that pass different names are fully isolated on disk. That single
string is the whole isolation mechanism, which is why it is a parameter rather than
a constant: the Mac app and the CLI deliberately pass the *same* name (§9), while a
test, a demo, or a second product passes its own and touches nothing.

It reaches exactly three things, and nothing else:

| Consumer | Effect |
|---|---|
| `DotfolderStack(name:)` | the two config locations below |
| transcript root (§5) | `~/.config/<name>/transcripts/…` |
| `profile.name` default | falls back to `<name>` when unset |

So the composed constructor carries it — `RoutedACPAgent(name:router:…)` (§9.1) —
and everything downstream receives *values* derived from it, never the name itself.

**Validation, because this string becomes a path component.** Reject empty, any
name containing `/`, `\`, or a path separator, `.` and `..`, and any name starting
with `.` (the dot is added by the project layer, never supplied). A name that
escapes its directory is a config-file-writing primitive pointed at an arbitrary
path, so this is a hard error at construction, not a warning.

#### The stack

`DotfolderStack` — **Extras'** type now (moved out of this package so the whole
family layers files one way; Shelltool's stacked `ShellPolicy` is the candidate
second adopter). Shipped as
`init(name:workingDirectory:defaultsDirectory:userDirectory:environment:)` —
`userDirectory` and `environment` are injectable so tests and demos never touch the
real home; this package passes no `defaultsDirectory` (layer 1 is code now, below).
It derives the locations and the precedence order:

1. **Builtin defaults — in code, not on disk.** *(Decided 2026-07-28, removing
   the shipped defaults directory.)* `AgentConfiguration`'s own property defaults
   *are* the default configuration: a curated coding-model profile that works out
   of the box on a 16 GB machine (`recording.level: full`,
   `transcripts.location: project`). There is no `config.yaml` to ship, nothing to
   materialize on first run, and no `<NAME>_DEFAULTS_DIR`.

   **This layer no longer exists as a directory**, and that is a real collapse
   rather than a renaming — after the last three decisions there is nothing left
   for it to hold. `config.yaml`'s defaults are code (here). `Instructions.md` is
   compiled in (§6.0). Builtin slash commands are Swift `.action` closures, and
   `skills/` plus `_partials/` are user-authored, so they live in layers 2 and 3
   by definition (§6.2). An empty directory with a first-run materialization
   step and an environment-variable override, holding nothing, is worse than no
   directory. So this package passes no `defaultsDirectory` to `DotfolderStack`;
   the parameter remains available in Extras for other adopters.

   **The swissarmyhammer lesson still holds**, because it was never really about
   files-vs-code — it was that *changing behavior must not require a rebuild*.
   Every artifact now has a code-level default you can shadow with a file you
   write, and §4's export command (below) writes that file for you. Nothing here
   needs a compiler to change.
2. **User layer — `~/.config/<name>/`** (no leading dot). Resolved as
   `$XDG_CONFIG_HOME/<name>/` when that variable is set *and* absolute, else
   `~/.config/<name>/`. Machine-wide preferences: "how I like this agent to
   behave, everywhere."
3. **Project layer — `<project>/.<name>/`** (leading dot). Per-repo overrides:
   "what this codebase requires of any agent working in it." `<project>` is the
   **agent's session working directory** — ACP's `session/new(cwd)` — not the
   process's cwd. That distinction is load-bearing: one process serves many
   sessions in different repos, so this layer is resolved *per session*, and two
   concurrent sessions legitimately see different project config.

#### Why one has a dot and the other does not

Not an inconsistency — each follows its own directory's convention, and getting
this backwards is the most likely implementation slip:

| | Path | Dot? | Why |
|---|---|---|---|
| User | `~/.config/<name>/` | **no** | `~/.config` is already a hidden directory; hiding files inside it is redundant, and XDG names its subdirectories bare |
| Project | `<project>/.<name>/` | **yes** | it sits at a repo root beside source, where the dot is what keeps it out of the way |

#### Every file in the stack

The same two locations carry every layered artifact, not just `config.yaml`:

| File | User layer | Project layer | Merge rule |
|---|---|---|---|
| `config.yaml` | ✅ | ✅ | key-level override (below) |
| `Instructions.md` (§6.0) | ✅ | ✅ | **wholesale replace**, nearest wins |
| `AGENTS.md` (§6.1) | ✅ | ✅ | **additive**, user first then project |
| *(skills are **not** in this stack — `~/.skills` + `<project>/.skills`, §6.2)* | — | — | — |
| `_partials/` (§4 templating) | ✅ | ✅ | nearest layer wins per partial name |
| `transcripts/` (§5) | opt-in | ✅ **default** | not layered — a location, not content |
| *(no per-tool config files — tools take **objects**, §4.1)* | — | — | `decisions.yaml` lands here once Shelltool `f9q2338` allows host-owned persistence |

Note `AGENTS.md` is the one **additive** row. Everything else answers "which layer
wins"; that one answers "in what order do they compose" (§6.1).

#### 4.1 Tool packages take objects, not config files

**Decision (2026-07-29): configuration is read in exactly one place — here — and tool
packages receive constructed values.** No tool package reads a config file of its own.

This is not a new rule, it is the rule the rest of the plan already follows and that
`shell` was quietly violating: Router receives values and never sees our config (§4);
Skills takes layer *roots* rather than naming a dotfolder convention (§6.2.1); FileTool
takes a root set and flags; `FoundationModelsMCP` takes server descriptions. Extras is
"the only thing that touches disk" for configuration. `ShellPolicy` reading its own
YAML from `~/.config/shell/` was the one exception, and an exception here costs more
than it saves: a user editing `tools: shell:` in our `config.yaml` and seeing no effect,
because the real rules came from a file they did not know existed.

*(This supersedes an earlier revision of this section, which proposed pointing
Shelltool's config URLs at our dotfolder. That was a half-measure — it relocated the
file I/O rather than removing it, and left two files a user could edit for one tool.)*

**So: `tools: shell:` in our `config.yaml` is the whole story**, decoded as Shelltool's
own option type per §7.1, and this package constructs a `ShellPolicy` value from it.

**The merge objection dissolves under the object model, which is worth spelling out
because the earlier revision argued the opposite.** Shell rules need
builtin ∪ user ∪ project, while §4's config merge replaces arrays wholesale — that
looked like a reason the ruleset needed its own file with its own merge. It is not,
once the policy is a value: the union happens **in code at construction**, not in YAML.

```swift
ShellPolicy(rules: ShellPolicy.builtinRules + configured, decisions: store)
```

The builtin denials are compiled into Shelltool and concatenated by us, so **no config
layer can remove them** — which is the security property that mattered, now enforced by
construction rather than by hoping a merge rule holds.

**One deliberate exception to §4's precedence, and it is security-shaped: denials
union across layers.** Every other key follows the normal later-layer-wins rule, but a
project-layer `deny` list must **not** replace a user's machine-wide one — otherwise
opening a repo could silently drop "never run `rm -rf`" from a user's own machine.
Denials are a floor, not a setting: builtin, user, and project denials all apply.
`allow` and `ask` follow ordinary override. Stated once here, implemented in our codec,
where it is visible — rather than as a second merge engine inside a config format.

**`decisions.yaml` is not configuration and needs its own answer.** Remembered
`allow_always` / `reject_always` answers are accumulated state that the *agent* writes,
not settings a user authors. The same ownership rule applies to the file: Shelltool
should define the decision vocabulary and the matching logic; **this package decides
where, and whether, it persists** — into our dotfolder, under our layering. Shelltool
already gets the important half right: `ShellDecisionStore.Scope` defaults to
`.session` — in memory, written nowhere — with `.project` / `.user` chosen deliberately.
That default matters now that the project dotfolder is **committed** (§5): a user
clicking "always allow" must not silently produce a tracked file change in a shared
repo. Preserve it.

**Compliance audit, 2026-07-29 — three of four already comply.** The rule is easy to
state and easy to check, because it has a mechanical test: **a tool package that
depends on Extras' `DotfolderStack` is doing configuration it should not be doing.**
Building the config stack is this package's job, and Extras is the substrate *we*
use — a leaf reaching for it is the smell.

| Package | Reads config files? | Extras dep | Verdict |
|---|---|---|---|
| `FoundationModelsFileTool` | none — takes `root`, `additionalRoots`, `readOnly`, `allowSymlinks` | no | ✅ complies |
| `FoundationModelsMCP` | none — takes server descriptions | no | ✅ complies |
| `FoundationModelsShelltool` | **YAML in three files** (`ShellPolicy`, `ShellDecisionStore`, `ShellDotfolder`) | **yes** | ❌ the sole violator |
| `FoundationModelsSkills` | takes **layer roots** (§6.2.1) | n/a — plan only | ✅ by design, see below |

Checked against the sources, not assumed: FileTool's and MCP's only `contentsOf:` uses
are array appends and reading files the tools *operate on*, never configuration.
Shelltool's Extras dependency exists specifically to resolve `~/.config/shell/` — so
**that dependency disappearing is the signal `f9q2338` is done**.

**Skills is different in kind, and its difference is the right one.** It takes a
folder stack rather than a config object, because for skills **the folders are the
data**: a skill *is* a directory containing `SKILL.md`, per agentskills.io. That is
content discovery, not self-configuration — the package still reads no config file and
still names no dotfolder convention. Same principle, different noun: **the host
supplies locations, the package supplies behavior** (§6.2.1). A skills registry handed
roots is exactly as compliant as a policy handed rules.

**Upstream ask on `FoundationModelsShelltool`.** None of this is possible today:
`ShellSecurityConfig` and `PatternRule` are internal, and the only public `ShellPolicy`
initializer takes config file URLs. Filed as Shelltool **`f9q2338`** — the requirement is that a host can build a
policy from values and supply its own persistence, with the file-reading path retained
for standalone use. Until it lands, the interim is to inject URLs pointing at our
dotfolder (the superseded design above), which keeps a single dotfolder even though it
does not yet keep a single file.

## 5. Transcripts: where recordings live

**Decision (revised 2026-07-28): project-local, keyed by ACP session —
`<cwd>/.<name>/transcripts/<sessionId>/`.** This reverses an earlier
"home, keyed by a project slug" decision. The reframe that changed it: **a
transcript is project context, not a personal activity log.** What the agent did to
*this* repo belongs *with* this repo — it travels when the repo travels, it is there
for a teammate who clones it, and "what did we try last week" is a question about the
codebase, not about the user.

Three things fall out for free, and one cost has to be paid deliberately.

**Project slugs are gone.** The `-Users-wballard-github-…` scheme existed only to
name a project inside a shared home root. With storage already inside the project,
the directory *is* the identity — nothing to encode, nothing to escape, nothing to
reverse for display.

**The organizing key is the ACP session, not the Router run.** Router's own layout
is `<recordingsDir>/<routerId ULID>/…` with a fresh id per process run, which groups
by *process lifetime* — an implementation detail no user has ever wanted to browse
by. The meaningful noun here is the **root ACP agent session**: it has a stable
`sessionId` that survives `session/resume`, it is what `session/list` enumerates, and
it is what a user means by "that conversation." A routerId may well correspond 1-1
with a run of the agent, but that is provenance, not structure — **record it as
metadata inside the session directory, not as a path segment.**

*Upstream: **resolved 2026-07-28.** Checking Router turned up a larger blocker than
the routerId segment — `Router.recordingsDir` was set once at `init`, so one Router
wrote every session under one root, which is fatal for project-local storage when one
agent process serves sessions in different repos. Filed as `ke41yth`; **it has landed**,
and in exactly the shape §5 needs:

```swift
func recordingDirectory(forSessionId: ULID, recordingRoot: URL? = nil) -> URL {
    if let recordingRoot {                       // flat: <root>/<sessionId>/
        return recordingRoot.appendingPathComponent(sessionId.description, …)
    }
    …                                            // legacy: <base>/<routerId>/<sessionId>/
}
```

So `makeSession(recordingRoot:)` yields `<cwd>/.<name>/transcripts/<sessionId>/`
directly — **no routerId segment**, which was the second half of the ask — while
omitting the parameter preserves the old layout byte-for-byte for existing callers.
Router's `PerSessionRecordingRootTests` covers both the flat layout and a fork
nesting under it. The ownership boundary held: Router took a *root*, not a policy, so
the dotfolder name and the project-vs-home-vs-absolute choice stayed here.*

**ACP's common case gets simpler, not harder.** `session/list` takes an optional
`cwd` filter, and an editor overwhelmingly wants "sessions for the project I have
open." Project-local storage makes that a single directory read instead of a
filtered walk over every project the user has ever touched.

Layout:

```
<cwd>/.<name>/                       # the same project dotfolder as config.yaml (§4)
    config.yaml                      # committable — team settings
    transcripts/
        .gitattributes               # linguist-generated + merge=union (committed, not ignored)
        sessions.jsonl               # this project's session index
        01K3G.../                    # ACP sessionId
            transcript.jsonl
```

### One ACP session is one root Router session — and nothing else is

*(Decided 2026-07-29. Getting this correspondence exact now is what keeps sub-agent
sessions well organized later, rather than needing a layout change once
`FoundationModelsAgents` lands.)*

**The ACP `sessionId` *is* the root Router session's ULID.** Not a mapping, not a
translation table — the same identifier, serialized. ACP's `SessionId` is an opaque
string and a ULID is one, so there is no reason to mint a second id and every reason
not to: a mapping table is a thing that can drift, and the first symptom would be a
`session/resume` that restores the wrong conversation.

**Router already distinguishes two kinds of descendant, and they are not the same
thing.** This is worth stating precisely because the words are easy to blur:

| | What it is | How it links | Directory |
|---|---|---|---|
| **fork** — `fork(workingDirectory:)` | a *branch of the same conversation* | `parentId` set to the parent session | nests: `<rootId>/<forkId>/` |
| **agent spawn** — `agentSpawn: AgentSpawn(parentSessionId:parentToolCallId:)` | a *sub-agent launched by a tool call*, possibly in another tree entirely | `parentToolCallId` — the tool call that spawned it | its own directory; linkage is the id, not nesting |

**Neither is an ACP session.** Forks and sub-agents never receive an ACP `sessionId`,
never appear in `session/list`, and never accept `session/prompt`. From the client's
side a sub-agent is something the agent *did* — a tool call with a `kind` and
content — not a second conversation it can talk to. That is the honest projection:
ACP's session noun means "a conversation a client drives," and a sub-agent is not one.

**`AgentSpawn.parentToolCallId` closes the identity chain.** It is documented as "the
correlation id a transcript browser matches against that turn's recorded tool-call
entry" — which is the *same* id as ACP's `toolCallId`, Router's
`SessionEvent.toolCall(id:)`, the MCP call handle, and `OperationEvent.correlationID`
(§9.2). So a sub-agent's transcript is reachable from exactly the tool call the client
watched execute, with no extra bookkeeping. One key, end to end, now spanning five
layers.

**Two rules fall out, and both are cheap only if written down now:**

- **`session/list` filters to roots.** A directory walk over project-local transcripts
  (§5) would otherwise surface nested fork directories and sibling sub-agent
  directories as if they were conversations. The test is exact: **listable iff
  `parentId == nil` and `agentSpawn == nil`.** Both facts are already on the sidecar,
  so this costs a predicate, not a schema.
- **`session/close` closes the tree.** v2 requires cancelling the session's ongoing
  work and freeing its resources "as if `session/cancel` had been called" — and a
  running fork or an in-flight sub-agent is that session's ongoing work. Closing the
  root must terminate its descendants, or a closed session keeps burning a model gate
  on work nobody is watching.

**Where a sub-agent's transcript lands, given project-local storage.** Router's model
says an agent spawn may sit "under an entirely different router or recording tree,"
which is right: a sub-agent given its own working directory belongs to *that*
project's transcripts, not the parent's. So sub-agents are **siblings** under whatever
project root their cwd implies, linked by `parentToolCallId` rather than by nesting —
while forks, which share the parent's conversation, keep nesting under it as Router
already does. The `session/list` predicate above is what keeps siblings from cluttering
the picker.

### Transcripts are committed — the transcript is the source

**Decision: transcripts are checked in, not ignored.** The framing is that a
transcript *is the new source*, and the code is its output: the prompts, decisions,
and corrections that produced a change are the durable artifact, and the diff is
what fell out of them. A repo that keeps only the diff has kept the compiled result
and thrown away the source.

That makes committing them the point, not a hazard to be mitigated — so the
`.gitignore` an earlier revision of this section specified is **deleted**, not
relocated. Nothing under `.<name>/` is ignored by default.

Consequences that follow, each of which is now a design obligation rather than a
footnote:

- **Per-session directories are what make this mergeable.** Two developers working
  concurrently produce two `sessionId` directories and two `transcript.jsonl` files,
  so their work never touches the same bytes — no conflict by construction. The one
  shared file is `sessions.jsonl`, the per-project index, which *will* conflict.
  Keep it **append-only with one self-contained record per line**, so a conflict
  resolves as a union of lines and `git merge` handles it with a union driver
  (`.gitattributes`: `sessions.jsonl merge=union`). Better still, treat it as a
  derivable cache — rebuildable by scanning session directories — so a mangled index
  is never load-bearing.
- **Mark them as generated.** `.gitattributes` with `linguist-generated=true` on
  `transcripts/**` keeps them out of language statistics and collapses them by
  default in PR review, so a two-line code change does not arrive as a
  ten-thousand-line diff. Reviewers who want the reasoning expand it deliberately.
- **Repo size is a real cost with no clean mitigation.** At `RecordingLevel.full` a
  transcript embeds the full contents of every file fed to a tool, and git keeps
  that forever — a few large refactor sessions can outweigh the source they
  produced. `recording.level` is the control, and it is per-project (§4), so a repo
  can choose `metadata` and keep the shape of its history without the payload.
  Say this plainly in the docs: full transcripts are the default because they are
  the valuable thing, and they are not free.

### No redaction — deliberately

**Decision: transcripts are recorded verbatim. There is no redaction pass, and
Router's `redact:` is not configured by this package.**

The operating assumption is stated plainly so it can be checked later: **this is a
development tool, running in development trees, against development credentials.**
A key that appears in a dev session is a dev key, and the control for a repo whose
history should not be public is the repo's own visibility — private by default, as
such repos already are. That is a real boundary, enforced by the host, rather than a
heuristic.

Two affirmative reasons, beyond the assumption:

- **Redaction corrupts the source.** Once the transcript *is* the source (above), a
  redaction pass edits it — and a pattern matcher that rewrites a line it
  misidentifies produces a record that no longer says what happened. A source you
  cannot trust to be faithful is worse than one you have to keep private.
- **Partial redaction invites misplaced confidence.** No pattern set catches every
  secret, so a "redacted" transcript is one someone will eventually treat as safe to
  publish. Verbatim-and-private is an honest posture; scrubbed-and-maybe-safe is not.

**`recording.level` remains the control for repos that want less**, committed in the
project layer so it applies to everyone working there rather than whoever
remembered: `metadata` records the shape of a session without its content, and `off`
records nothing. That is a per-repo decision about what is worth keeping, which is
the right place for it — not a per-string guess made at write time.

**If the assumption ever stops holding** — a public repo, a regulated codebase,
production credentials in a dev tree — the answer is `recording.level`, not
redaction. Worth a line in the docs where the feature is described, so the premise
is visible to someone whose situation differs.

**Deleting the checkout deletes the working copy, not the history** — the transcripts
travel with the repo, which is the intent. Note this also changes what
`session/delete` can honestly promise: it removes the session from the working tree
and the index, but anything already committed remains in git history, and the ACP
response cannot claim otherwise.

### Cross-project browsing needs an index

The app's session browser wants "what was I doing in repo X last week?" across
everything. That was a directory walk under one home root; it is now a
filesystem-wide hunt, and this is the one capability the reversal genuinely costs.

**Keep a project registry in the user layer** — `~/.config/<name>/projects.jsonl`,
appended when a session is created in a cwd not seen before: the absolute path, first
seen, last seen. It holds **paths only, never content**, so it re-introduces none of
the leak surface the transcripts themselves carry. It is a cache, not a record:
regenerable, safe to delete, and stale entries (a repo since deleted or moved) are
skipped on read rather than pruned eagerly.

`transcripts.location` still overrides: `home` restores the old shared-root behavior
for a user who wants it (with the slug scheme, which survives *only* for that mode),
and an absolute path wins outright. The default is now `project`.

`TranscriptStore` exposes the read side both frontends need:
`sessions(inProject:)` — now a plain directory read — `allProjects()` via the
registry above, and `transcript(for sessionID:) -> [Transcript.Entry]` via Router's
`TranscriptTree` reconstruction. Session *restoration* into a live session already
exists upstream (`RoutedLLM.restoreSessionTree`); the store just locates the
directory to feed it.

**`session/list` sets the read side's real requirements (§9.1).** ACP's
`SessionInfo` is richer than "lightweight summary" implies, and four of its fields
are obligations rather than passthroughs:

- **`title`** — human-readable, and v2 says it "may be auto-generated from the first
  prompt." Nothing generates or persists one today. Decision: derive it from the
  first user prompt (truncated, single-line), persist it alongside the session's
  entry in `sessions.jsonl`, and emit `session_info_update` when it first appears so
  a live client's tab label stops saying "Untitled." A model-generated title is a
  nicer follow-up, not day one.
- **`updatedAt`** — RFC 3339, last activity. Cheap from the record, but it must be
  *maintained*, which means the store reads it rather than stat-ing a file.
- **`additionalDirectories`** — the session's **complete ordered** additional-root
  list (§9.1, now that the capability is advertised). It is not derivable from `cwd`
  and not recoverable after the fact, so it must be **persisted per session** — and
  persisted as an *ordered list*, not a set, since the spec obliges us to report the
  "complete ordered additional-root list" and a `Set<URL>` round-trip would silently
  drop information. It is *replaced* on every `session/resume` rather than
  accumulated, so the stored value tracks the most recent activation.
- **`cursor` / `nextCursor`** — `session/list` is **cursor-paginated**. Cursors are
  opaque to clients (they MUST NOT parse, modify, or persist them), we enforce a
  bounded page size, and an invalid cursor is an error. So `sessions(inProject:)`
  returning everything is not sufficient; the store needs a paged variant, and the
  cursor should encode a stable sort key (`updatedAt` descending + `sessionId` as
  tiebreak) rather than an offset, so pagination survives concurrent writes.

**`session/delete` — revised 2026-07-28 to a soft delete, and the reversal matters.**
An earlier revision of this section decided a **hard** delete: unlink the session
directory, "because a soft-deleted transcript still contains the prompts." That
reasoning was sound when it was written and stopped being sound a few decisions
later, when transcripts became **committed source** rather than a privacy hazard to
contain. Two things changed under it:

- **The protocol asks for far less than we were offering.** The schema is narrow and
  explicit: `DeleteSessionRequest` is "Request parameters for deleting an existing
  session **from `session/list`**," and the capability means "the agent supports
  deleting sessions **from `session/list`**." The normative requirement is only that
  "deleted sessions no longer appear in future `session/list` results," and the page
  says outright that soft-versus-hard "is not mandated — only the user-facing
  behavior matters." We were volunteering destruction the spec never asked for.
- **Destroying source on a list-removal gesture is disproportionate.** Under §5's own
  framing the transcript *is* the source and the code is its output. A client
  affordance that removes an item from a picker must not delete tracked files — it
  would also stage a git deletion the user then has to reckon with, which is the
  agent quietly editing a repo as a side effect of a UI click.

And the original privacy argument no longer even pays: transcripts are committed, so
a hard delete leaves the content in git history regardless. It buys nothing and costs
the source.

**Decision: advertise `capabilities.session.delete` and implement it as delisting.**
Mark the session deleted — a tombstone in `sessions.jsonl`, which is append-only and
already the listability index (§`session/list`) — and **leave `transcript.jsonl`
untouched on disk**. `session/list` stops returning it, which is precisely and
entirely what the protocol requires. Deleting the *content* stays a deliberate act the
user performs on their own repo with their own tools, which is the right place for a
destructive operation on committed source.

**Two implementation-defined behaviors the spec hands us; both decided:**

- **Deleting an active session:** close it first (`session/close` semantics — cancel
  work, emit `idle` with `stopReason: "cancelled"`, free resources), then delist.
- **Resuming a deleted session:** **error.** With the transcript still on disk, resume
  could technically succeed, but a delete gesture that a later resume silently undoes
  is not a delete. Recovery is un-tombstoning the record by hand, not a protocol call.

Already-deleted and never-existent both **SHOULD succeed silently** — with a tombstone
this is naturally idempotent, which is a small argument in its own favor.

The ownership boundary, stated plainly: **`TranscriptStore` never records and
never restores.** It owns exactly three things — the root location policy, the
project registry, and lightweight browse summaries (read via Router's own
readers). Everything that gives a `transcript.jsonl` its meaning — writing
events, reconstructing entries, applying compaction checkpoints, rebuilding a
live session — is Router's, and this package calls Router to do it.


### 6.0 The system prompt — `Instructions.md`, a stacked markdown file

*(Decided 2026-07-28, replacing the `instructions.replace` / `instructions.append`
config keys, which are deleted. A system prompt is prose; packing prose into YAML
is unnatural to write, awkward to diff, and hostile to the templating and
`{% include %}` machinery every other markdown document here already gets.)*

**The base prompt is one markdown file, resolved through the same layering as
everything else** — nearest layer wins, wholesale:

| Layer | Location | Notes |
|---|---|---|
| 1 | **compiled in** | the guaranteed floor; never edited, only shadowed |
| 2 | `~/.config/<name>/Instructions.md` | machine-wide replacement |
| 3 | `<project>/.<name>/Instructions.md` | per-repo replacement |

**This is now the ordinary case, not an exception.** An earlier revision argued
`Instructions.md` was a carve-out from a "real files, never embedded" rule for the
defaults directory. **That directory is gone** (§4): config defaults are code, and
so is the base prompt. Layer 1 is code for everything, uniformly — which is a
simpler rule than the one it replaces, and it removes the drift risk of a shipped
file that must be kept in sync with the code that reads it.

What makes the prompt worth calling out is still true and still the reason the
floor must exist: **it is the one artifact where *nothing* is not a valid value.**
Absent config means defaults (§7.1); an absent `commands/` means no commands; an
absent system prompt means a silently lobotomized agent rather than an error. So
the compiled-in text is a **floor**, not an edit surface. The swissarmyhammer
lesson survives intact, because it was never files-vs-code — it was that changing
behavior must not require a rebuild. You never edit layer 1; you shadow it, and
shadowing never involves a build.

**Replacement is wholesale, and addition has its own lane.** A layer-3
`Instructions.md` replaces the base entirely — merging prose is meaningless, and
this matches the family's full-replace override rule (§4). What used to be
`instructions.append` is **already served by AGENTS.md** (§6.1): user-level and
project-level agent-instruction files are appended after the base, they are
markdown, and "prefer swift-testing over XCTest" is exactly the kind of thing
[agents.md](https://agents.md/) exists to carry. So deleting `append` loses no
capability — it redirects the use case to the file type built for it. The two
lanes stay cleanly separated: **`Instructions.md` replaces, `AGENTS.md` adds.**

**Discoverability is the cost of a compiled-in floor**, and it has to be paid
explicitly: a file you cannot see is a file you cannot fork. Two obligations, both
already implied by §4's published-artifact contract — the text is reproduced
verbatim in DocC/README, and the CLI can both print the assembled prompt and
**eject the builtin** to a layer-2/3 path as a starting point for editing
(`<cli> instructions --eject`) — the exact counterpart of `/config export` (§4),
and for the same reason: a default that lives in code has to be writable to disk on
demand, or it cannot be forked. Consider a `/instructions export home|project`
builtin alongside `/config export` so the two are symmetric from inside a
session.

Templating follows §4's one rule, unchanged: the compiled-in copy renders
**trusted**; layer-2 and layer-3 overrides render **untrusted**.

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

Assembly order (completing §4's and §6.0's picture): base prompt
(`Instructions.md`, nearest layer — §6.0) → user-level `AGENTS.md` →
project-level documents (root → cwd). There is no trailing config-supplied
segment any more; the last word belongs to the nearest `AGENTS.md`. Each file is delimited by a
header naming its absolute path, so both the model and anyone reading the
session's `instructions` (the published-artifact contract, §4) can attribute
every line. Missing files are simply absent; a present-but-unreadable file is
a logged warning, not the hard error config files get — this is content, not
configuration. Each document renders through Extras' template engine
(untrusted, §4) before assembly, so partials and env vars work in AGENTS.md
exactly as they do in command templates.

The assembled text is read once at session creation, folded into the
`instructions` value handed to `makeSession`, and pinned for the
session's lifetime — a new session picks up edits. Instructions are never
folded by compaction (Router compaction plan §1.3 invariants), so this
context survives every fold by construction. Router never knows any of
this happened; the session just receives longer instructions.

### 6.2 Slash commands — one registry, three sources

Slash commands are a session-level noun: `/compact` acts on *this* session,
and a skill discovered in *this* repo becomes a command in *this* session
only. So this package keeps one registry per session, assembled at session
creation like tools and instructions, and re-published when a source changes.

**The cross-package currency is Extras' `SlashCommand`**: `name` /
`description` / `argumentHint` plus a two-kind `Body` — `.prompt(template:)`
expands into an ordinary model turn; `.action` runs code and streams text,
never touching the model. Contributors implement `SlashCommandProviding`
(`commands(workingDirectory:)` + optional `commandUpdates` stream) against
the leaf, never this package — the dependency diamond keeps arrows pointing
only downward.

Three sources, merged in precedence order (later wins on name collision,
logged; builtin names are reserved and never overridden):

1. **Builtins** — this package's `.action` closures capturing the session:
   `/compact` (force compaction now), `/context` (fill, tokens, resolved
   context), `/memory` (print the assembled instructions with source headers —
   §4's published artifact, interactive), `/status` (session id, cwd,
   model/profile, transcript path), `/config` (print the effective configuration
   as commented YAML; `/config export home|project` writes it to that layer —
   §4), `/help`. Frontend verbs (`/quit`,
   clear-as-new) stay out — composer affordances, same rule as queueing.
2. **Linked providers** — `SlashCommandProviding` conformers registered by
   catalog roster entries (§7.1): the *code-backed* lane. Only linked Swift
   can construct `.action` — the trust boundary; in-process code is already
   trusted as tools. Skills is the flagship future conformer (one `.prompt`
   command per discovered skill, pushed via `commandUpdates` as files
   change). Day one ships the seam, not a conformer.
3. **Skills** — the *data* lane, and as of 2026-07-28 the **only** one.
   **`~/.skills/<id>/SKILL.md` and `<project>/.skills/<id>/SKILL.md`**,
   discovered and rendered by **`FoundationModelsSkills`**, surfaced through
   `SlashCommandProviding`. One skill = one `/id` command.

   **Note these are *outside* the `<name>`-qualified stack**, deliberately — see
   "Where skills live" below.

   *(This replaces a `commands/*.md` template lane that used to live here.
   Skills is a strict superset — frontmatter validation, a real parameter model,
   `_partials/`, preloading, bundled resources and scripts — over the same two
   directories with the same trust rules. Two overlapping ways to define a
   prompt command was one too many, and the weaker one went.)*

   The trust boundary is unchanged and still absolute: skill markdown is **data**
   and can only ever produce a prompt. A broken or malicious `SKILL.md` at worst
   yields a bad prompt under normal tool confinement — it can never become
   `.action`.

   (MCP prompts remain the reserved further source: `prompts/list` +
   `listChanged` feed this same registry once the MCP roster entry lands.)

**Dispatch lives at the prompt owner** — this package's `prompt()` handler
for the wire, and the frontends' composers for direct consumption — Router's
sessions know nothing of commands, and a `/compact` typed in an editor must
never reach the model as a prompt. A leading `/name` routes through the registry
*before* anything touches the session: `.prompt` expands (template +
arguments) into a normal recorded turn; `.action` streams output with **no
model turn and no transcript entries** beyond what the action itself records
(`/compact` its `CompactionSegment`; `/help` nothing). Unknown `/name`
errors with near-matches — never a model turn; frontends escape a literal
leading slash.

**A command may arrive with other content attached** — the spec allows
"`/deploy prod`" to be accompanied by an image or a `resource_link` in the same
prompt — so dispatch must say what happens to the remaining blocks. `.prompt` and
skill commands expand into a model turn, so the extra blocks **ride along into that
turn**; dropping them would discard the file the user deliberately attached to the
command they ran. `.action` commands take no model turn, so attachments have nowhere
to go: **refuse the invocation with a reason** rather than silently discarding them.
Silence is the only handling that is definitely wrong. Registry mechanics (merge, precedence, near-miss matching,
`commandUpdates` re-publication) are this package's; the vocabulary is
Extras'.

On every registry change: the published per-session command set updates (CLI
autocomplete, app palette) and the ACP conformance fires
`available_commands_update` (§9.1) — the protocol noun this registry peers
with.


### 6.2.1 Where skills live — `~/.skills` and `<project>/.skills`

**Decision (2026-07-28): skills sit outside the `<name>`-qualified stack**, at
`~/.skills/<id>/SKILL.md` and `<project>/.skills/<id>/SKILL.md`. Two layers, user
then project, nearest wins by directory name — the same precedence as everything
else, but rooted differently.

**Why unqualified.** `<name>` exists to isolate *products* (§4): two frontends
passing different names share nothing. That is right for configuration, instructions,
and transcripts, all of which describe how *this agent* behaves. A skill is not that.
[agentskills.io](https://agentskills.io) is an ecosystem format, and a "deploy to
staging" skill is a property of the **user** and the **repo**, not of whichever agent
happens to read it. Namespacing skills under `<name>` would mean writing a skill once
per product and keeping the copies in sync, which is exactly the outcome a shared
format exists to prevent.

There is already precedent in this plan: §6.1's project-level `AGENTS.md` is
*unqualified* for the same reason — it is an ecosystem artifact — while the
user-level one is namespaced because a home-directory `AGENTS.md` is our extension
with no spec behind it. Skills follow the ecosystem rule on both layers.

**The consequence, stated plainly: `<name>` isolation does not extend to skills.**
Two agents built on this stack with different dotfolder names share one skill
library. That is the intent, not an oversight — but §4 makes a point of name-based
isolation, so the exception belongs on the record.

**`~/.skills` is a deliberate divergence from the XDG rule** §4 follows for config.
The reasoning that put configuration at `~/.config/<name>/` (no dot, because
`~/.config` is already hidden) does not transfer: this is not our config, it is a
library many tools may read, so it takes the older shared-convention shape —
`~/.ssh`, `~/.gnupg` — and matches its project-side sibling `<project>/.skills`
exactly. *(If XDG consistency is preferred later, `~/.config/skills/` is the
alternative and would come free from `DotfolderStack(name: "skills")`, whose project
layer already resolves to `<cwd>/.skills`. Noted, not recommended.)*

**Ownership: the `.skills` literal belongs here, not in Skills.** This is the same
rule the rest of the plan follows — the frontend passes `<name>` and this package
derives locations (§4); Router receives values, never policy (§5's recording root).
So **`FoundationModelsSkills` takes its roots as a construction parameter** — an
ordered list, lowest precedence first — and holds no opinion about `.skills`, `~`, or
dotfolders. This package computes `[~/.skills, <cwd>/.skills]` and passes them in.

Two things follow. Skills stays reusable: another host can put its library anywhere
without a fork or a flag. And there is **no upstream dependency on `DotfolderStack`**
for this, which matters because `DotfolderStack` cannot express `~/.skills` — it
always yields `~/.config/<name>/` on the user side. Skills' plan currently describes
discovery "over `DotfolderStack.layers`"; that needs to become "over the roots it is
given." A plan-level change there, with no code to migrate.

**The `skills:` config section stays in the `<name>` stack**, which is not a
contradiction: the *content* is shared, the *behavior* is per-agent. `skills: false`
disables discovery for this agent without touching anybody's library.

**Trust:** both layers are untrusted (§4) — neither is a builtin default — so skill
markdown renders under the untrusted template rules and can only ever produce a
prompt.

### 6.3 Skills review — does the slash-command story actually work?

*(Reviewed 2026-07-28 against `../FoundationModelsSkills/plan.md` and Extras'
shipped `SlashCommand`. Verdict: **the design is sound and the mapping is real, but
two things must change before it works** — one in Extras, one here.)*

**What lines up.** Skills already models discovery as an ordered two-layer walk with
full-replace by directory name — the same precedence shape this package uses
everywhere else — so pointing it at `~/.skills` and `<project>/.skills` (§6.2.1) is a
change of *roots*, not of mechanism. `SkillListing.id` is
documented as "directory name = the `/command`", and its §7.1 already describes the
user-driven path exactly as §6.2 needs it: the listing informs the UI, and invoking
resolves to `registry.call(id:arguments:)` whose **rendered body becomes the turn's
input** (`root.respond(to: rendered)`). That is `.prompt` semantics, and hot reload
is already contemplated (`onReload`), which is what `commandUpdates` needs.

**Gap 1 — Extras' `SlashCommand.Body` has no case that fits.** It offers exactly
two:

```swift
case prompt(template: String)                                     // data lane
case action(@Sendable (Invocation) -> AsyncThrowingStream<String, Error>)  // code lane
```

Skills fits neither. It is not `.prompt(template:)`: Skills renders with **its own**
pipeline and argument model (`$0`/`$1`/`$ARGUMENTS[N]`/`$name`, `_partials/`, shell
injection), so handing the raw `SKILL.md` body over as a "template" would have this
package render it with Extras' Stencil engine under the *wrong* substitution rules —
silently wrong output, not an error. And it is not `.action`, which is defined as
"runs code, streams text output, **never touches the model**" — whereas the entire
point of a skill command is that the rendered body *does* become a model turn.

**Needed: a third body kind that computes a prompt and then takes a normal turn** —
shape roughly `case rendered(@Sendable (Invocation) async throws -> String)`, where
the conformer renders and the dispatcher feeds the result to the model exactly as it
would a `.prompt`. Filed on Extras as **`c2pad49`**. **The trust boundary survives**,
which is what makes this safe to add: a closure can only be constructed by linked
Swift, so data still cannot reach the code lane; the new case merely lets *linked
code* produce model input instead of streamed output.

**Severity: wanted, not blocking — Skills already documents the workaround.** Its §6
says the `.prompt` re-render "runs none of §5's passes 1–2" and that "a host that
wants full render fidelity calls `registry.call(id:arguments:)` directly." We are
that host: this package owns the §6.2 registry, so it can hold skill commands as its
own internal kind, dispatch them through `registry.call`, and feed the result to the
model — no Extras change required. The cost is that Skills stops being an *ordinary*
provider and becomes a special case in our dispatcher, which erodes the rule that the
cross-package vocabulary is Extras'. Take the workaround if `c2pad49` is slow; prefer
the case.

**Gap 2 — ACP flattens the parameter model, and we choose how.** Skills carries a
real one: `SkillParameter { name, position, required, variadic, placeholder }` plus
`acceptsTrailingArguments`. ACP v2's `AvailableCommandInput` is a single
`{type: "text", hint: String}` (§9.1). So a three-parameter skill arrives at the
client as one free-text hint, and that is ACP's limit, not something we can fix.
**Decision: pass Skills' own `argument-hint:` string through verbatim as the ACP
hint** — it is already written in exactly the display syntax an editor wants
(`<env> [region] [flags...]`), so the lossy step at least loses nothing a human
reader needs. Structured parameter prompting is an `_meta` extension if a client
ever wants it.

**Scope, stated honestly.** Skills is **plan-only**: 808 lines of plan, no sources,
no board. Calling it a day-one built-in alongside `files` and `shell` — both built
and tested — is a real commitment, and the phasing matters. The saving grace is that
the two halves have very different dependency chains:

| Half | Needs | Depends on |
|---|---|---|
| `/id` slash commands | Skills M1–M3 + M5 | **Extras only** — shipped |
| `search`/`list`/`use` tool | Skills M4 | `FoundationModelsOperations` 2/4/5 **and** `FoundationModelsMetadataRegistry` M1–M4 — neither built |

So the command lane is genuinely achievable day one, and the tool lane is not. Ship
the conformer first; let the model-facing tool follow when its upstreams land. Any
plan that treats "skills as a built-in" as one indivisible item will stall on
packages that have not started.

## 7. Tools

### 7.1 The catalog — the well-marked follow-up location

`Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift` is the single
place tools are registered — the well-known names for our well-known tools
(head decision): each linked package gets one reserved config section, and
adding a tool is a dependency plus one catalog line:

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

### The enable/disable rule

**Every built-in is on unless the config turns it off.** One rule, five shapes an
entry can take:

| Config | Meaning |
|---|---|
| no `tools:` section at all | every built-in on, each with its own defaults |
| `tools:` present, tool not mentioned | that tool on, with its defaults |
| `shell: {}` / `shell:` (null) | on, with defaults — explicit but redundant |
| `shell: {policy: strict}` | on, body decoded as **that package's own option type** |
| **`shell: false`** | **off** — the tool is not constructed and never reaches the model |

`false` is the disable form, and it is deliberately *outside* the body rather than
an `enabled: false` key *inside* it. The body is the tool package's own option
type, and §4's rule is that unknown keys inside a known section are errors — so an
`enabled:` key would have to be added to every tool package's option struct, making
each one carry a flag that only this layer cares about. Keeping it outside means
the codec checks for a scalar `false` first and only then decodes the mapping, and
the tool packages stay ignorant of the concept. (`true` is accepted as a synonym
for `{}`, so a config that says `shell: true` is not a confusing error.)

Disabling is per-tool and one at a time, by design. There is no `tools: false`
mass-switch and no `only:` allowlist: an agent that genuinely wants nothing says so
tool by tool, and that verbosity is the point — a config that silently removed the
whole roster would be too easy to write by accident.

**Consequence worth stating: a new built-in arrives enabled.** Because absence
enables, adding `codeContext:` to the roster (§7.3) turns it on for every existing
user on upgrade without a config edit. That is the intended "batteries included"
behavior and matches how the defaults layer is meant to work — but it means adding
a roster entry is a user-visible capability change, not a silent internal one, and
should be released like one.

Layering is §4's ordinary key-level override, so precedence falls out: a user layer
may disable a tool the defaults enable, and a project layer may re-enable it with
`shell: {}`. The nearest layer that mentions the tool wins.

**`mcp:` is the one entry whose body is a list, and it needs the rule spelled out.**
It carries servers rather than options, so "on with defaults" means something
different for it:

- **omitted** — MCP is *enabled with no configured servers*. It contributes no tools
  of its own, but the ACP client's per-session `mcpServers` (§8.7) are still
  connected. This is the default, and it is the right one: an editor that supplies
  its own servers works against a stock config.
- **`mcp: [ … ]`** — those servers, plus any the client supplies.
- **`mcp: false`** — MCP off entirely, which additionally means **client-supplied
  ACP servers are refused**. That is a real and deliberate security posture ("this
  agent talks to nothing I did not link"), not merely an empty list, so it must be
  distinguishable from `mcp: []` — and it is: the empty list configures zero local
  servers while still honoring the client's, `false` honors nothing. When a client
  does supply servers to an `mcp: false` agent, log the refusal rather than
  silently dropping them; a client whose servers vanish without explanation is the
  worst version of this.

### `ToolContext`

`ToolContext` carries what every tool needs (the session working directory and the
session's additional roots, the decoded config section) so constructors stay
uniform. Frontends may
append their own tools when constructing the agent — the merged array is
what `makeSession(tools:)` receives.

**Day one, `builtin(context:)` composes four sibling packages** (head decision),
all four declared in this package's `Package.swift` — three contributing tools, one
contributing slash commands:

- **`FoundationModelsFileTool`** → the `files` tool, confined by `PathGuard` to a
  **root set**: the session's working directory plus the session's
  `additionalDirectories` (§9.1). `cwd` stays the privileged member — it is the
  relative-path base — but a path resolving inside any root validates.
- **`FoundationModelsShelltool`** → the `shell` tool, gated by the stacked
  `ShellPolicy` the `shell:` config section configures — now a three-outcome policy
  (`.allow` / `.ask(reason)` / `.deny(message)`) with a `ShellDecisionStore` behind
  `remember(...)`, which is what `session/request_permission` and its
  `allow_always` / `reject_always` options bind to (§9.1).

  **Note the shell is not root-confined, and `additionalDirectories` does not change
  that.** `ShellContext` carries no workspace root, and `check(workingDirectory:)`
  validates only `..` traversal and existence — confinement for `shell` is
  command-and-environment pattern rules, not a filesystem boundary. So multi-root
  support is a `files`/`PathGuard` concern only. The honest consequence, worth stating
  rather than implying otherwise: a shell command's blast radius is bounded by policy
  rules, not by the workspace, and widening the workspace does not widen it. Whether
  `shell` *should* additionally be root-confined is a separate open question, not
  something ACP's `additionalDirectories` forces.
- **`FoundationModelsMCP`** → `MCPToolProvider`, which turns every configured
  *and* client-supplied MCP server (§8.7) into `[any Tool]`. Unlike the other
  two this one is dynamic: the tools it yields depend on what the servers
  advertise, and connection must complete before the array reaches
  `makeSession(tools:)`.

- **`FoundationModelsSkills`** → **both a tool and a command provider**, and it is
  the reason this list says "packages" rather than "tools." The two halves are not
  two ways to do one thing; they answer different questions:

  | Surface | Answers | For whom |
  |---|---|---|
  | the **tool** (`search skill` / `list skill` / `use skill`) | *"what can I do here?"* — **discovery**, when the caller does not know the skill exists | the model |
  | the **command provider** (`/id` via `SlashCommandProviding`) | *"do this specific thing"* — **explicit dispatch**, when the caller already knows | the user |

  Skills' own plan splits exactly this way — §7 is the fused `OperationTool` and its
  "model-driven" invocation path; §6 is `commandListing()` and the "user-driven"
  path — and §7.1's catalog is the registration point for both, since an entry may
  pair a tool with a `SlashCommandProviding` conformer.

  Neither half is redundant, which is what makes the readiness gap consequential
  rather than cosmetic (§6.3). The command half depends only on Extras, shipped; the
  tool half needs Skills M4 and through it two packages that do not exist yet. So
  day one ships **explicit dispatch without discovery**: skills work when the user
  already knows what they want, and are invisible otherwise — including to the
  model, which cannot find or invoke them at all. That is a real difference from
  `files` and `shell`, which give the model capability from the first turn, and it
  is worth deciding deliberately rather than inheriting from a dependency chain.

The first three are the whole of the agent's reach into the user's world, which ACP v2
makes the protocol's own position rather than our convenience (§8.6): v2 deleted
`fs/read_text_file`, `fs/write_text_file`, and all five `terminal/*` client
methods and redirected agents to their own file access and their own execution,
with MCP as the standard route for both. So `files` + `shell` + `mcp` are not
three of many candidate roster entries — they are the agent's file access, its
execution, and its extensibility, and the roster is incomplete without any one
of them.

Catalog entries are also where slash-command providers register (§6.2): an
entry may pair its tool with a `SlashCommandProviding` conformer (from
`FoundationModelsExtras`) and the catalog feeds it into the session's command
registry. The direction rule is absolute — tool packages conform to the
*leaf's* protocol; nothing outside this package ever names its types.


### 7.3 The tool roster (composed as each package ships)

Each tool is one catalog entry plus (usually) one dependency. Reserved config
section names keep the schema forward-compatible (§4).

**Built in, day one — declared dependencies, in the default roster:**

| Tool | Source package | Blocked on | Config section |
|---|---|---|---|
| `files` | `FoundationModelsFileTool` (**built**) — first builtin entry | nothing | `files:` |
| `shell` | `FoundationModelsShelltool` (**built**) — second builtin entry | nothing | `shell:` |
| MCP servers | `FoundationModelsMCP` (**built**) — `MCPToolProvider`; third builtin entry, and the one v2 promotes to load-bearing (§8.6) | nothing; the ACP tunnel transport is unstable-schema-gated (§8.7) | `mcp:` (plus ACP's per-session `mcpServers`) |
| skills → `/id` commands | `FoundationModelsSkills` (**plan-only**) — its user-facing half, a `SlashCommandProviding` conformer | Skills M1–M3 + M5; Extras only (already shipped) | `skills:` |
| skills → `search`/`list`/`use` tool | `FoundationModelsSkills` (**plan-only**) — the model-facing half | Skills M4, which needs `FoundationModelsOperations` 2/4/5 **and** `FoundationModelsMetadataRegistry` M1–M4 | `skills:` |

**Follow-ups — added one catalog line at a time as each package ships:**

| Tool | Source | Blocked on | Config section |
|---|---|---|---|
| code-context ops (`searchSymbol`, `callGraph`, `blastRadius`, …) | thin `Tool` shim over `CodeContext` — explicitly left to consumers | nothing; first follow-up | `codeContext:` |
| `runCode` | `MultiTool` (JS composition over the catalog) | nothing | `multitool:` |
| sub-agents | FoundationModelsAgents | that package (plan-only) | `agents:` |


## 8. Elicitation: the user round-trip lives here

**Decision: this package owns elicitation.** It is the only layer with a live
bidirectional channel to something that has a user — the ACP client on the other
end of the connection. `FoundationModelsMCP` defines the
`ElicitationCoordinator` protocol and deliberately owns no UI; Router owns no
user channel at all (`SessionOutbox`/`SessionEvent` is a one-way *outbound*
projection, not a request/response with a human). So the coordinator is
implemented **here**, as `ACPElicitationCoordinator`.

### It is a relay, not a translation

MCP and ACP elicitation are near-isomorphic, which is what makes this cheap:

| MCP (swift-sdk) | ACP (`protocol/v2/elicitation` — unstable schema) |
|---|---|
| `CreateElicitation` `.form(FormParameters{message, mode?, requestedSchema})` | `elicitation/create`, `mode: "form"`, `message`, `requestedSchema` |
| `.url(URLParameters{message, mode, url, elicitationId})` | `mode: "url"`, `message`, `url`, `elicitationId` |
| `Result.Action { accept, decline, cancel }` | `action: accept \| decline \| cancel` (+ optional `content`) |
| `notifications/elicitation/complete { elicitationId }` | `elicitation/complete { elicitationId }` (agent → client) |

Both directions of MCP elicitation route through the one coordinator: a **server**
pausing mid-tool-call, and the **model** asking via `MCPElicitationTool`.

### What this package must implement

- **`ACPElicitationCoordinator: ElicitationCoordinator`**, holding the
  `AgentSideConnection`. `elicit` → `elicitation/create`, awaiting the client's
  `action`/`content`; `complete(elicitationId:)` → `elicitation/complete`.
- **Scope every request.** ACP requires `sessionId` (optionally with
  **`toolCallId`**) or a `requestId` for interactions outside a session. Map the
  MCP **call handle → `toolCallId`**, so the client can show *which* tool call is
  asking — including a **detached, long-running** one, which is the case that
  otherwise prompts the user out of nowhere.
- **Gate on capability, degrade honestly — but note the gate moved in v2.** The
  documented shape is a client advertising elicitation support with `form` and `url`
  each present and non-null, and agents **MUST NOT** request an unsupported mode
  (`-32602`). In **stable v2 there is no such field**: `ClientCapabilities` carries
  only `_meta`, so elicitation support is an `_meta`-negotiated extension for as
  long as `elicitation/*` lives in the unstable schema. Treat *absent* as
  *unsupported* — the safe default — and when the needed mode is unsupported return
  MCP **`decline` with a clear reason**, never a lossy squeeze into
  `session/request_permission`, which is options-based (`[PermissionOption]` +
  `subject`) and cannot carry a `requestedSchema`.
- **Relay URL-mode completion.** URL mode is a *three-message* flow: create →
  accept → `elicitation/complete { elicitationId }`. Forward MCP's
  `notifications/elicitation/complete` straight through; the ids match by design.
- **Honor the spec's security duties**, which are ours as the agent: form mode
  MUST NOT request secrets; URL-mode credentials MUST NOT come back over ACP; the
  client displays the target host and obtains consent; and the agent **MUST verify
  the authenticated user identity matches between elicitation initiation and
  completion**; HTTPS outside development; no prefetching.
- **Do not stall the model.** Wrap the client round-trip in Router's
  `awaitingUser { }` (see Router's plan → Concurrency). `Tool.call` is `async`, so
  awaiting a human already suspends the FoundationModels loop correctly — but
  Router holds a **per-model** generation gate across the whole turn, so a naive
  await blocks every other session and fork on that model for as long as the user
  takes. This package is the right caller for that release, because it is the one
  place that knows both "I am about to block on a person" and "Router holds the
  gate." That also keeps `FoundationModelsMCP` free of any Router dependency.
- **Report the block on the wire, not just internally.** v2 gives blocked-on-human
  a protocol representation, so the `awaitingUser { }` release and the
  `state_update` transition are two halves of one action: emit `requires_action`
  when entering the round-trip and `running` when the answer arrives (§9.1). A
  client that sees `running` while we are silently waiting on a person renders a
  hung agent; that is exactly the failure `requires_action` exists to prevent.

### Prerequisite in `FoundationModelsACP`

`elicitation/create` and `elicitation/complete` are present in
`Schema/acp-v2.meta.unstable.json` as **method names only** — `.client` side, with
no generated request/response types and no handlers anywhere in the package. They
are **not in `acp-v2.meta.json`**, so all of §8 is unstable-schema work: a
stable-only client cannot participate, and the payload shapes may still change
before they graduate.

Two consequences worth stating plainly. First, the wire types and the client-side
handler entry points have to land in `FoundationModelsACP` first — this package
cannot implement the coordinator against a method table alone. Second, **§8 is
therefore not day-one scope**, and `FoundationModelsMCP`'s
`ElicitationCoordinator` needs a non-ACP fallback for the interim: a coordinator
that declines every elicitation with a clear "this host cannot ask you questions
yet" reason is honest and unblocks the MCP built-in (§7.1) without waiting on the
unstable surface.

## 8.6 ACP v2: what the reframe changes here

**We target ACP v2 only** (see `FoundationModelsACP`'s Decision: v2 only). v2 is a
large simplification, not a cosmetic revision, and four of its changes land squarely
on this package.

### The turn model inverts — and it fits us better

**v1:** `session/prompt` stayed pending for the whole turn and resolved with a
`stopReason`.
**v2:** it returns `{}` **immediately**, acknowledging acceptance. Progress and
completion arrive as **`state_update`** notifications: `running`, `idle` (carrying
`stopReason`), and **`requires_action`** (foreground work blocked on the user).
Cancellation is confirmed by an `idle` state with `stopReason: "cancelled"`.

This is a better fit for what we actually built:

- **Long-running work stops fighting the protocol.** A detached MCP call, a
  soft-deadline shell command — none of it has to resolve before we answer the
  prompt. We acknowledge, then report.
- **`requires_action` is the state elicitation always needed.** A blocked
  permission or elicitation now has a protocol-level representation instead of
  looking like a stalled turn.
- **`session/cancel` has a defined confirmation.** It is an `idle` state with
  `stopReason: "cancelled"`, which is the report a client renders — though *making*
  cancellation reach an in-flight turn is still Router's gap.

### The agent owns history, and the protocol says so

Every message chunk and update carries a required, **agent-generated `messageId`**:
*"the Agent owns session history, so it is the single source of message identity."*
That is our "the FoundationModels `Transcript` is the record" invariant, promoted
from our design choice to the protocol's own position (§9.2).

`session/resume` with `replayFrom: {"type": "start"}` then makes replay a
first-class request: we replay history as ordinary session updates when asked. So
this package owes a **transcript → session-update replay** path, which is also what
makes a reconnecting client correct rather than stale.

**The one thing v2 does not give us outright** is a dedicated "history was
rewritten" notification, so a connected client could still drift after a compaction.
**Decided in §9.2: re-emit the affected messages as upserts** — `agent_message` /
`user_message` keyed by `messageId`, `content: null` for what the fold removed —
with `session/resume` + `replayFrom` as the reconnection fallback. That works
because v2's message upserts can replace *or clear* content, so history rewriting is
expressible in the protocol's own vocabulary rather than an `_meta` extension. The
open dependency is upstream: Router's `CompactionResult` must carry message-level
identity so we know which `messageId`s a fold touched.

### `fs` and `terminal` move to MCP, which promotes MCP to load-bearing

v2 **removes** `fs/read_text_file`, `fs/write_text_file`, and all five `terminal/*`
client methods, and redirects both explicitly: agents use **MCP servers for
client-side file access** and **MCP for client-side execution**. Combined with
*"stable v2 defines no standard client capability fields,"* the client's job shrinks
to rendering and answering prompts.

For §7.3's roster that is a promotion, not a loss: `FoundationModelsFileTool`,
`FoundationModelsShelltool`, and `FoundationModelsMCP` are now the *only* way the
agent reaches the user's world, and v2 says that is the correct side of the protocol
for them to live on.

**Agent-owned display terminals are the counterpart — and they are real
(verified 2026-07-26 against the vendored `acp-v2.json`).** An earlier revision of
this section recorded them as unverified and told us not to plan the plumbing,
because neither the v2 Content page nor a (nonexistent) v2 Terminals page shows
them. That was a docs artifact: **terminals are documented under Tool Calls**, and
the schema carries the whole mechanism:

| Schema type | What it is |
|---|---|
| `TerminalId` | "Unique identifier for an agent-owned terminal within a session." |
| `Terminal` (a `ToolCallContent` variant) | "A display-only reference to an agent-owned terminal" — `{terminalId}`; state and output arrive separately |
| `TerminalUpdate` (`session/update`) | Upsert of stored terminal state; only `terminalId` required, other fields patch (omitted = unchanged, `null` = cleared) |
| `TerminalOutputChunk` (`session/update`) | "A chunk of bytes appended to an agent-owned terminal's output" — independently base64-encoded |
| `TerminalOutput` | "An authoritative replacement snapshot of terminal output bytes" |
| `TerminalExitStatus` | `{exitCode?, signal?}`; "the presence of this object marks the terminal as exited, even when neither an exit code nor a signal is known" |

So the mapping this section previously called "obvious and attractive" is now
**planned work**, and it is `shell:`'s user-visible payoff as a built-in (§7.1):

- Shelltool's `commandID` → `terminalId`. One identity again, alongside
  `toolCallId` / `OperationEvent.correlationID` (§8.7).
- Incremental line streaming → `terminal_output_chunk` (base64 per chunk, so
  byte-faithful — no lossy text coercion of a program's raw stdout).
- Shelltool's stored record → `TerminalOutput`, the authoritative replacement
  snapshot, which is exactly what a reconnecting or truncation-recovering client
  needs.
- Command exit → `TerminalUpdate.exitStatus`. Note the "exited even when unknown"
  semantics fit a soft-deadline kill precisely.
- The tool call emits a `Terminal` content reference; the bytes ride the terminal
  stream, not the tool-call content. **Display-only** — this is not the removed
  `terminal/*` client-execution surface coming back; we execute, the client renders.

Sequencing: the terminal stream is additive over ordinary tool-call content, so
`shell` ships text-in-`content` first and gains the terminal stream as a
follow-up — but plan for it, and do not design the shell tool's output path in a
way that discards raw bytes before the wire.

### Modes become config options

`session/set_mode` and the `modes` response field are gone, replaced by
`session/set_config_option` and `config_option_update` with categories `mode`,
`model`, `model_config`, and `thought_level`. Model selection — which is
Router's whole job — is now expressed as a **config option**, so profile/model
switching gets a protocol-native surface it did not have. `current_mode_update` is
removed.

### Smaller, but load-bearing

- `authenticate` → `auth/login`; `logout` → `auth/logout` (required when
  `authMethods` is non-empty).
- **`session/close`** is new and the agent **MUST** cancel that session's ongoing
  work and free resources — which for us means cancelling in-flight MCP calls and
  detached work, and ties directly to Router's in-flight cancellation gap.
- `tool_call` create is gone; `tool_call_update` is an upsert, `status` gains
  `cancelled` and is **extensible** — so our MCP `lost` outcome rides as **`_lost`**
  instead of being flattened into `failed`. The underscore is mandatory, not stylistic:
  unknown non-underscore values are reserved for future ACP variants and implementations
  **MUST NOT** treat them as custom extensions.
- MCP config: required `type` discriminator, **`sse` removed**, per-transport
  capabilities `session.mcp.stdio` / `session.mcp.http`, and `args` / `env` /
  `headers` now optional.

## 8.7 MCP wiring: two sources, two transports (+ one unstable), two sinks

§7.3's roster lists MCP servers as one catalog entry fed by an `mcp:` config
section. That is **half the story**, and the missing half is ACP-specific: **ACP
itself carries MCP servers.** `session/new` and `session/resume` take
`mcpServers: [McpServer]`, and in v2 the `type` discriminator is **required** with
exactly two cases: `.stdio(McpServerStdio{type, name, command: AbsolutePath, args?,
env?})` and `.http(McpServerHttp{type, name, url, headers?})`. **`sse` is removed**
— there is no `McpServerSse` — and `args` / `env` / `headers` are now optional
rather than required-but-empty. ACP assumes agents run MCP, and the **client**
decides which servers they run.

### Two sources of servers

Local `mcp:` config **and** the ACP client's per-session `mcpServers`. Both must
compose, with a stated rule: client-supplied servers are session-scoped and
arrive *after* config-derived ones, so precedence, name collisions (ACP's `name`
is our `ServerIdentity`), and whether a client may override a configured server
all need answers. Note `session/resume` carries the list too (v2 folded
`session/load` into it) — a restored session must reconnect the same servers.

**Never persist the client-supplied list.** `session/resume` carries `mcpServers`
itself, so **the client is the source of truth on every reconnect** and we simply use
what we are handed. That is both simpler — no storage, no staleness, no reconciling a
stored list against a supplied one — and necessary: an `http` server's `headers` carry
bearer tokens, and §5 makes session metadata project-local and **committed**, so
persisting them would write live credentials into a shared repo. Config-derived
servers (`mcp:` in a project `config.yaml`) are the user's own committed file and
their own decision; §4's `{{ env.TOKEN }}` templating is how the secret stays out of
it. Router's `session.json` sidecar is already clean here — slot, model, context,
recording level, profile, and no MCP configuration — so this is a constraint on our
`sessions.jsonl`, not an upstream ask.

Because `sessionTools()` is async and Router's tool-instancing pipeline is
synchronous, connection must complete **before** the tool array reaches
`makeSession(tools:)`. For client-supplied servers that means during
`session/new`/`session/resume` handling.

### Two transports in stable v2 — and a third that is unstable-only

Stable v2's `McpCapabilities` has exactly two fields, `stdio` and `http`. **`sse`
is gone**: v2 removed the HTTP+SSE server type outright, so there is no
`McpServerSse` case to construct and no third stable transport to support.

- **stdio** → `StdioServerProcess`, whose API mirrors `McpServerStdio`'s fields, so
  the mapping is field-for-field with no adapter. Advertised as
  `capabilities.session.mcp.stdio`.
- **http** → `HTTPClientTransport`, with ACP's `headers` supplying auth
  (authorization stays the host's job per `FoundationModelsMCP`'s decision).
  Advertised as `capabilities.session.mcp.http`.

**The ACP tunnel is unstable-schema-only — plan it, gate it, don't promise it.**
`mcp/connect` + `mcp/message` (bidirectional) + `mcp/disconnect` appear in
`acp-v2.meta.unstable.json`, **not** in `acp-v2.meta.json`. There is no stable-v2
capability that advertises a tunnel, so a stable-only client can never ask for one.
The design is still right and still ours: the **client** hosts the server and the
agent tunnels MCP JSON-RPC over ACP; **`ACPTunnelTransport` belongs in this
package** — it is an `MCP.Transport` conformance that needs ACP types, and
`FoundationModelsMCP` must never depend on `FoundationModelsACP`. It plugs into
that package's transport factory like any other transport, and in this mode the
client owns the processes, so `StdioServerProcess` is bypassed entirely. But it is
**doubly blocked**: on the wire package generating the `mcp/*` payload types (they
are routing entries with no types today), and on the methods graduating to stable
— and if they graduate, the shape may change. Ship stdio + http first; treat the
tunnel as a follow-up behind the unstable schema.

Whichever transports we support must be advertised as **`McpCapabilities`** at
`initialize` (`capabilities.session.mcp`); nothing does that today.

### Two sinks for one tool call

A long-running MCP call has to report to **both** audiences, and they are
different channels:

- **model-visible** — `OperationEvent` → Router's `SessionOutbox` → transcript.
- **user-visible** — `session/update` with `ToolCall`/`ToolCallUpdate`:
  `toolCallId`, `status` (`pending`/`in_progress`/`completed`/`failed`/`cancelled`,
  and extensible via `_`-prefixed values), `content`,
  `kind`, `locations`, `rawInput`, `rawOutput`.

One identity spans all of it: the MCP **call handle** becomes the
`OperationEvent.correlationID`, the ACP `toolCallId`, *and* the `toolCallId`
scoping an elicitation (§8). A **detached** MCP call is exactly why ACP's `status`
stays `in_progress` across turns.

Mapping details that need deciding rather than defaulting:

- ACP has no *standard* `lost` status, but v2's `ToolCallStatus` is **extensible**,
  so a dropped MCP connection rides as **`_lost`** rather than flattening into
  `failed` — underscore mandatory (§Extensibility). Still put "we do not know whether this ran"
  in the accompanying text, for clients that ignore the custom value.
- `rawInput` / `rawOutput` / `content` / `locations` need the **structured per-call
  record** from `FoundationModelsMCP`, not its model-facing rendered string, which
  is deliberately elided.
- **`ToolAnnotations` → `ToolKind`** is the right use of MCP's *untrusted* hints:
  a UI hint feeding a UI hint (icon and treatment), never a gate.
- **`destructiveHint` / `openWorldHint` → `session/request_permission`** is where
  `FoundationModelsMCP`'s "hosts may gate on annotations" decision actually gets
  realized. The bridge never gates; this package may.

### Cancellation must chain

`session/cancel` → in-flight MCP call does **not** work today, and the break is in
the middle: Router's cancellation is queue-side, and a turn already handed to the
model runs to completion. Chaining it needs Router's in-flight cancellation first;
even then MCP's `notifications/cancelled` is advisory, so the honest UI outcome is
"we stopped listening," not "it stopped."

## 9. Frontends: the shared-consumption contract

Three consumers share this composition: the Mac app, the CLI, and **any ACP client**
(Zed, editors — §9.1). The app and CLI are out of scope to *build* here, but every
contract is in scope to *prove*:

- Both construct **this package's composed agent** with the **same dotfolder
  name** — that single string is what makes config and transcripts shared.
  The name is chosen by the frontend, not baked into any layer below.
- The CLI is a thin ArgumentParser wrapper: parse args → construct agent → render the
  session event stream to the terminal. The `acp-agent` executable *is* this CLI in
  miniature and doubles as the living contract test; the production CLI likely grows
  in its own repo from a copy of it.
- **The Mac app is itself an ACP client, in-process.** `InMemoryTransport.pair()`
  is public, so the app runs this composed agent in-process and speaks ACP to it —
  the *same* interface Zed uses, over a different transport. It then lands the ACP
  event stream in `@Observable` containers and binds those to SwiftUI (§9.2).
  *(Supersedes the earlier "the Mac app binds Router's observable session state":
  binding Router directly would create a second, drifting path to the UI beside
  the one every external client sees.)*
- **Infrastructure state still comes from Router directly.** `ResolutionProgress`
  (model download/load progress, residency) is **not session content** and ACP has
  no notification for it, so the app binds Router's `@MainActor @Observable`
  `ResolutionProgress` as before. The split is the rule: **session content flows
  over ACP; infrastructure state comes from Router.**
- The history browser uses `TranscriptStore.allProjects()`/`sessions(inProject:)`.

### 9.2 The record, the interface, and the observable container

Three representations, in a strict derivation order — this is the architecture, and
it only stays coherent if the direction is never reversed:

```
Transcript (FoundationModels)          THE RECORD — authoritative, and non-monotonic
   |  Router projects changes
SessionEvent  +  SessionProjection     keyed on Apple's own Transcript.ToolCall.id
   |  this package maps
ACP session/update                     THE INTERFACE — append-only wire stream
   |  InMemoryTransport (in-process) or stdio (external clients)
ACP Client conformance = @Observable    SwiftUI binds this
```

**ACP is a projection, never a second record.** Every `session/update` must be
derivable from the transcript. The corollary is what makes it safe: an observable
container must be **rehydratable** via `session/resume` with
`replayFrom: {"type": "start"}`, not merely accumulated from a live stream it might
have joined late or missed messages from. The transcript is
what backs that replay.

The identity chain established elsewhere pays off here again: Apple's
`Transcript.ToolCall.id` = Router's `SessionEvent.toolCall(id:)` = ACP's
`toolCallId` = the MCP call handle = `OperationEvent.correlationID` =
**`AgentSpawn.parentToolCallId`** (§5). One stable key across five layers — which is
also what SwiftUI `ForEach` needs, and what makes a sub-agent's transcript reachable
from exactly the tool call the client watched execute.

**Mapping, and where it runs out:**

| Router `SessionEvent` | ACP `SessionUpdate` (v2 discriminator) |
|---|---|
| `textDelta` | `agent_message_chunk` (with the agent-generated `messageId`) |
| `reasoningDelta` | `agent_thought_chunk` |
| `toolCall(id:name:argumentsJSON:)` | `tool_call_update` — **v2 removed the `tool_call` create variant**; the first update carrying an unseen `toolCallId` *is* the creation, and it SHOULD carry `title` |
| `toolStatus(id:status:summary:)` | `tool_call_update` (`running` → `in_progress`) |
| `compaction(CompactionResult)` | `agent_message` / `user_message` upserts — see below |
| `turnEnded(TokenUsage)` | `usage_update` — `UsageUpdate {used, size, cost?}`, "context window and cost update for a session" |
| turn start / turn end | `state_update` — `running`, then `idle(stopReason)` (§9.1) |

Note the v2 discriminators are **`snake_case`** (`agent_message_chunk`,
`tool_call_update`, `in_progress`) while JSON *properties* are `camelCase` — the
spec's convention, and an easy place to get the wire wrong.

ACP's `ToolCallStatus` adds `pending`, which Router's lacks — useful, since a
*queued* call is `pending` while a *detached* MCP call is `in_progress`. v2 also
adds `cancelled`, and the enum is **extensible**, so MCP's `lost` outcome rides as
**`_lost`** rather than flattening into `failed` (§8.7).

**`usage_update` is the context meter, and it is native.** An earlier revision of
this table recorded `turnEnded(TokenUsage)` as having no peer and needing `_meta`.
It has a first-class one: `used` / `size` map straight onto Router's token metering
and resolved context, so the fill gauge every frontend wants is a protocol noun, not
an extension. Consequence for §6.2: `/context` now duplicates a wire notification —
keep the command for CLI ergonomics if it earns its keep, but the app should bind
`usage_update`, not invoke a slash command.

**`session_info_update` has a peer too.** Session titles change (v2 says a title
"may be auto-generated from the first prompt"), and `session_info_update` is how a
live client learns. See §9.1's session-metadata row.

**Compaction is the hard problem — and v2 solves most of it.** Compaction
**rewrites history**: entries the UI already displayed cease to exist in the record,
so a container that only accumulates goes silently stale.

A previous revision decided this with a history-invalidation marker in `_meta` plus a
client-side re-`session/load`. **Both halves are superseded.** `session/load` does
not exist in v2, and — more importantly — v2's messages are no longer append-only:
`user_message`, `agent_message`, and `agent_thought` are **whole-message upserts**
keyed by the agent-owned `messageId`, with uniform patch semantics (*omitted field =
unchanged, `null` = cleared, value = replaced, chunks append*).

**Decided (v2):** on compaction, emit `agent_message` / `user_message` upserts for
the affected `messageId`s — `content: null` for messages the fold removed, replaced
`content` for any it rewrote — plus one `agent_message` for the summary the fold
produced. History rewriting is expressible in the protocol's own vocabulary, no
`_meta` extension and no client round-trip. This is why the agent owning `messageId`
matters: v2 states outright that *"the Agent owns session history, so it is the
single source of message identity"* — which promotes our "the FoundationModels
`Transcript` is the record" invariant from a design choice to the protocol's
position.

The fallback stays available and is what makes a *reconnecting* client correct:
`session/resume` with `replayFrom: {"type": "start"}` replays the whole conversation
as ordinary `session/update` notifications. So a client that missed the upserts (or
joined late) rehydrates from the record rather than guessing. Treating a fold as
invisible is still not an option; papering over it with appends would still make the
interface lie about the record.

**Open, and worth pushing upstream:** the upsert path requires us to *know* which
`messageId`s a fold touched. Router's `CompactionResult` must therefore carry
message-level identity, not just a checkpoint — an upstream ask on Router's
compaction work, and the one piece of this that is not purely local.

**Coalescing is a requirement, not an optimization.** `textDelta` arrives at token
rate; applying each one to an `@Observable` on the main actor will thrash SwiftUI.
The container must batch deltas and flush on a display-rate cadence, appending into
the in-flight message rather than rebuilding arrays.

**The transcript stays directly reachable.** This package exposes the session (and
so its `Transcript`) to the frontend for authoritative inspection, history, and
debugging. That is a *second view of a derived-from source*, not a second source:
live UI binds the ACP stream; the transcript is the thing that stream is a
projection of.
- **Sandboxing decision:** sharing `~/.config/<name>` and `$CWD/<anywhere>` is incompatible
  with the App Sandbox. Recommendation: the Mac app ships **non-sandboxed** (a
  developer tool operating on arbitrary repos — the norm for this product class; it
  can still be notarized and hardened-runtime). If sandboxing ever becomes mandatory,
  the fallback is security-scoped bookmarks per project plus moving the home layer to
  `~/Library/Application Support/<name>/` with the CLI honoring the same path — the
  `DotfolderStack` seam localizes that change. Decide before the app ships; nothing in
  this package blocks on it.

### 9.1 ACP: this package's agent composes the runtime

`RoutedACPAgent` — this package's `Agent` conformance — composes Router's
self-folding sessions with the config, roster, and command registry from
§§4–7.
ACP is an **application protocol** — its nouns (cwd sessions, prompt turns,
visible tool calls, stop reasons, session management, available commands)
are owned across the stack this package assembles, and a wire protocol
attaches at the layer that owns its nouns (a language *server* speaks LSP; a
parser doesn't). The lower layers never pretend to be agents:
`RoutedSession` stays Router's wire-free session surface,
`LanguageModelSession` stays Apple's conversation primitive.

**The wire is the sibling package** (`../FoundationModelsACP`): generated
schema types (vendored v1.19.x), the `Agent`/`Client` role protocols, the
`*SideConnection` full-duplex runtime, ndJSON framing — zero dependencies,
spec'd there.

#### `initialize` — the details the peering table is too coarse for

*(Audited against the v2 Initialization page + vendored `acp-v2.json`, 2026-07-28.)*

**`info` is required, and we had not said what goes in it.** `InitializeResponse`
requires `protocolVersion` **and** `info`, and `Implementation` requires `name` and
`version` (`title` optional). So the agent must identify itself; this is not a field
we may skip. Report `name` as the programmatic identifier (stable, machine-facing —
the package/product name, *not* the dotfolder `<name>`, which is a user's private
choice and has no business on the wire), `title` as the human-readable display name,
and `version` as the build's version for display and bug reports. Clients surface
these, so they are user-visible.

**Version negotiation has a defined behavior we must implement, not just a number.**
`ProtocolVersion` is a `uint16`. The rules: the client sends the latest it supports;
if we support it we **MUST** echo the same integer; otherwise we **MUST** respond
with the latest *we* support, and the client **SHOULD** close the connection. Since
this package is v2-only, the concrete behavior is: **a client that sends `1` gets `2`
back and a normal successful response — not an error.** Refusing or erroring would
violate the negotiation contract; the spec deliberately puts the disconnect decision
on the client. Log it, answer honestly, let them hang up.

**Capability markers are objects, not booleans, all the way down.**
`PromptCapabilities` members are `PromptImageCapabilities` / `PromptAudioCapabilities`
/ `PromptEmbeddedContextCapabilities`, and `mcp`'s are `McpStdioCapabilities` /
`McpHttpCapabilities` — each supplied as `{}` to mean "supported", omitted or `null`
to mean "not". No `true` anywhere.

**`capabilities.auth` exists and we omit it.** `AgentAuthCapabilities` is a real
field, and its schema is explicit that it "does not advertise support for
`auth/login` or `auth/logout`" — those are advertised solely by a non-empty
`authMethods`. We have neither: no `authMethods`, so the methods are excused, and no
`capabilities.auth`, because there are no auth extensions to declare. Both omitted,
per the standing rule that a thing with no peer is switched off rather than faked.

**Reading the client's capabilities: absent means unsupported.** The spec is explicit
— *"Clients and Agents MUST treat all capabilities omitted in the `initialize`
request as UNSUPPORTED."* Stable v2's `ClientCapabilities` carries only `_meta`, so
today there is nothing to read; the rule still matters because §8's elicitation gate
is `_meta`-negotiated and must default to *unsupported* when the key is missing.
Same rule, one place — do not let the two drift.

**Be forgiving about malformed capabilities.** The schema marks `capabilities`
`x-deserialize-default-on-error` with `default: {}`. A capabilities object we cannot
parse degrades to "supports nothing" rather than failing `initialize` — a client with
a newer or broken shape still gets a working connection at baseline.

**Ordering: `initialize` comes first, and we enforce it.** Clients **MUST**
initialize before creating a session. A `session/*` call arriving before a completed
`initialize` is a protocol error and should be answered as one (JSON-RPC invalid
request) rather than served — serving it would mean acting on capabilities that were
never negotiated. Cheap to check, and it turns a confusing downstream failure into an
obvious one.

#### Authentication — none, and the plan was already right

*(Audited 2026-07-28. **No changes needed to the decision**: a local on-device agent
has no authentication surface. The spec agrees explicitly — "Agents without
authentication needs simply omit `authMethods` from initialization responses.")*

Confirmed against the schema, so the existing peering row is accurate rather than
merely plausible: omitting `authMethods` removes the obligation to implement
`auth/login` and `auth/logout` ("An Agent that does so **MUST** implement both"), and
clients **MUST NOT** call either method when the list is empty or absent.
`AuthMethodAgent` does key on `methodId` as the row claims. `auth_required` (**-32000**,
"Authentication is required before this operation can be performed") is never raised,
because nothing here ever requires authentication.

One detail worth pinning: **a buggy client that calls `auth/login` anyway gets
`-32601`**, whose schema text is "The method does not exist **or is not available**."
That second clause is what makes it the right code — the method exists in the
protocol but not on this agent — rather than `-32600` invalid-request. Post-logout
semantics ("the protocol does not guarantee what happens to already-running
sessions") are moot for us.

**But "no ACP auth" is not "no credentials," and the two must not blur.** ACP
authenticates *the agent to the client*; that is what we do without. **MCP servers
are a separate axis and do carry credentials** — an `http` server's `headers`
(§8.7), supplied either by our config or by the ACP client in `session/new`. So
tokens do travel over this connection even though the connection itself is
unauthenticated.

**That collides with two other decisions in this plan, and the resolution is a rule:**
§8.7 requires a resumed session to reconnect the same MCP servers, and §5 makes
session metadata project-local and **committed**. Persisting a client-supplied
`mcpServers` list to satisfy the first would write bearer tokens into a file that the
second commits to a shared repo — a far worse leak than anything §5's no-redaction
decision contemplates, because it is a live credential rather than a dev-shaped
secret in prose.

**Rule: never persist client-supplied MCP server configurations.** No need exists —
`session/resume` carries `mcpServers` itself, so the **client is the source of truth**
on every reconnect and we simply use what we are handed. Config-derived servers
(`mcp:` in a project `config.yaml`) are the user's own committed file and their own
decision; templating `{{ env.GITHUB_TOKEN }}` (§4) is what keeps a token out of it,
and that is the documented pattern. Router's `session.json` sidecar is already clean
here — it records slot, model, context, recording level, and profile, and no MCP
configuration at all — so this is a constraint on *this* package's `sessions.jsonl`,
not an upstream ask.

#### Session setup — five things the peering rows do not capture

*(Audited against the v2 Session Setup page + vendored `acp-v2.json`, 2026-07-28.)*

**1. `configOptions` is returned at session setup, not only from `set`.** Both
`NewSessionResponse` (`required: ["sessionId"]`, plus optional `configOptions`) and
`ResumeSessionResponse` (nothing required, plus optional `configOptions`) carry it.
The config-options row below is written around `session/set_config_option`, which
misses where the list is *first advertised*: **the `session/new` response is the
primary announcement**, ordered by priority, and a client that never calls `set`
still renders whatever we return there. Consequence for the model selector — the
obvious first option — is that it must be constructible at session-creation time,
before any turn has run.

**2. Replay uses whole-message upserts, not chunks.** The spec: replay "includes user
messages, agent responses, and thoughts, each identified by unique `messageId`," and
"message updates that omit `content` can update other optional fields without
changing the current content." So a replay emits `user_message` / `agent_message` /
`agent_thought` — the upsert variants — **not** the `*_chunk` stream a live turn
produces. Replaying as chunks would work by accident on a lenient client and is wrong
on a strict one; more importantly it would make replay slower and larger than the
record it is derived from. Same `messageId`s as the original turns, which is what
lets a client that already saw some of them converge rather than duplicate.

**3. `ReplayFrom` is designed as a cursor, and `start` is only its first variant.**
The schema calls it an "inclusive cursor describing where replayed session history
should begin. Replay includes the position identified by the cursor," with `start`
plus an `other` extension slot. We implement `start` and absent — that is the whole
of stable v2 — but the replay path should be written so the *cursor* is the
parameter, not hardcoded to "everything," because resuming from a message id is the
obvious next variant and a `replayAll()` shaped function would have to be rewritten
rather than extended.

**4. `session/close` inherits cancellation's full semantics, including its
notification.** The spec is precise: close means "cancel any ongoing work for that
session **as if `session/cancel` had been called**, then free the resources." That is
stronger than "stop the work" — cancellation (§Prompt Lifecycle) requires answering
every pending `session/request_permission` with the cancelled outcome and emitting
`state_update` `idle` with `stopReason: "cancelled"`. So a close during an active turn
**emits that `idle` update before the close response**, rather than going quiet. A
client that had a spinner up otherwise never learns the turn ended. Then free
resources: in-flight MCP calls, detached work, spawned stdio processes (§8.7).

**5. `env` and `headers` are arrays of `{name, value}`, not maps.** `EnvVariable` and
`HttpHeader` both `required: ["name", "value"]`. Trivial, and exactly the kind of
thing that gets written as a dictionary by reflex and then fails to round-trip.
Duplicate names are therefore representable on the wire — decide last-wins and move
on. Note also that `McpServerStdio` requires only `name` + `command` and
`McpServerHttp` only `name` + `url`, so `args`, `env`, and `headers` are all
genuinely optional and must not be defaulted to empty-and-required.

#### `session/list` — one correction and two decisions the spec leaves to us

*(Audited 2026-07-28.)*

**Correction: `title` and `updatedAt` are optional, not owed.** `SessionInfo` requires
only **`sessionId` and `cwd`**; `title`, `updatedAt`, and `additionalDirectories` are
all optional. An earlier revision of this plan said we "owe title generation" — that
overstated the spec. Generating a title remains the right *product* decision (§5: a
client tab reading "Untitled" is a worse experience than one reading "fix the resume
cursor"), but it is a choice we are making, not a conformance requirement, and it
should not block anything.

**`cwd` and `additionalDirectories` are immutable once a session exists.**
`SessionInfoUpdate` carries **only** `title` and `updatedAt` (each nullable to clear)
— there is no field for `cwd` or the root list. Two consequences:

- It confirms the resume rule from the other direction: a mismatched `cwd` on
  `session/resume` must be **rejected**, because there is no mechanism by which a
  session's `cwd` could legitimately change.
- **There is no way to push a root-list change.** `session/resume` may legitimately
  activate a different `additionalDirectories` set (§Session Setup), but no
  notification can report that — a connected client only learns on its next
  `session/list`. Nothing to fix here; it is a protocol gap. Report the *most recent*
  activation in `SessionInfo` and do not attempt to synthesize an update for it.

**Decision 1 — ordering is unspecified, so it is ours, and the cursor must match it.**
The spec says nothing about the order of returned sessions. We sort **`updatedAt`
descending, `sessionId` as tiebreak** (§5), because "what was I just working on" is
the question a session list answers. The cursor encodes that same sort key rather than
an offset, so a session written mid-pagination cannot cause a duplicate or a skip.
Both halves have to agree — an ordering chosen in the query and a cursor built on
something else is the classic source of items appearing twice.

**Decision 2 — what is listable is undefined, so state it.** The spec does not say
whether closed, deleted, or never-prompted sessions appear. Ours:

| Session state | Listed? | Why |
|---|---|---|
| active | yes | obviously |
| closed (`session/close`) | **yes** | closing frees resources but retains the transcript (§5); resuming it is the entire point |
| deleted (`session/delete`) | no | delete removes it from history by definition |
| created, zero turns | **no** | it has no transcript worth resuming, and listing it is noise in every client's picker |

The zero-turn rule falls out of §5's layout for free: a session directory is written
when there is something to record, so "has a persisted transcript" *is* the
listability test — no extra state to track.

**The `cwd` filter is cheap now, and its miss case is not an error.** Project-local
storage (§5) makes a filtered list a single directory read. An unfiltered list is the
expensive one, answered through the `projects.jsonl` registry. A filter naming a
directory we have never seen returns an **empty `sessions` array, not an error** —
"no sessions here" is a normal answer, and a client opening a fresh project asks it
constantly.

#### Session config options — what we can actually offer, and it is not nothing

*(Audited 2026-07-28. The peering row below says "day one may ship an empty
`configOptions` array." That is conformant but defeatist — there is one genuinely
useful option available with **no upstream work**, and shipping it is what makes the
surface real rather than declared.)*

**Day one: one `select`, category `model`, offering the resident profile's slots.**
Router resolves a profile into `standard` / `flash` / `embedding` slots, and standard
versus flash is a real quality-versus-speed choice a user wants per session. Both are
**already resident**, so switching between them loads nothing and blocks on nothing —
in particular it does **not** need Router `kh01tv2` (pooled residency), which is only
required to switch *profiles*, i.e. to models that are not loaded. State that
distinction in the option's `description` so a user does not read "model" and expect
the whole candidate list.

What we deliberately do **not** offer, each for a reason already decided elsewhere:
`model_config` context size (§4: derived from the model, deliberately not
configurable), `mode` (no modes exist here), `thought_level` (Router exposes no
reasoning-level knob). Anything with no peer stays absent rather than faked.

**`currentValue` must track reality, which makes `config_option_update` load-bearing
rather than decorative.** The spec names "falling back to a different model" as a
trigger, and Router's joint-fit genuinely does pick among candidates by what fits the
host budget. So when resolution lands on a different model than the option currently
advertises, push a `config_option_update` — otherwise the client's selector claims a
model the agent is not running, which is exactly the silent lie §9.1's honesty rule
exists to prevent.

**Four schema details the row glosses:**

- **Grouping is a wrapper, not a field.** `SessionConfigSelectOptions` has two
  variants — ungrouped (a flat `[SessionConfigSelectOption]`) and grouped (a
  `[SessionConfigSelectGroup]`, each `required: ["groupId", "name", "options"]`). So
  `groupId` names a *group object containing options*, rather than tagging an option.
  We ship ungrouped; the distinction matters only so nobody models it as a field.
- **Array order is significant.** "The order of the `configOptions` array is
  significant" and agents SHOULD put higher-priority options first; clients use it to
  break category ties and to choose what to show when space is limited. With one
  option this is free — but it means the array is a priority list, not a set, the
  moment there are two.
- **Both `set` and the push carry the complete state.**
  `SetSessionConfigOptionResponse` and `ConfigOptionUpdate` are each
  `required: ["configOptions"]` — the *full* set every time, never a delta. That is
  what lets a change to one option restate the others when they depend on it.
- **`SessionConfigOption` requires only `configId` + `name`** at the base, with
  `select` / `boolean` / `other` variants supplying `currentValue` (and `options` for
  select). `description` and `category` are optional, and **categories are UX-only —
  "MUST NOT be required for correctness."**

**Every option MUST have a default**, so a client that ignores config options entirely
still gets a working session — which is the same graceful-degradation rule the
capability system runs on.

#### Prompt lifecycle — the upsert algebra, and the cancellation contract

*(Audited 2026-07-28. Two corrections landed in the rows below — response-before-
`user_message` ordering, and catching the cancellation exception. Three further
things are worth stating once, because everything else in the plan depends on them.)*

**The upsert algebra, exactly.** The spec gives a worked example, and it is the
foundation §9.2's compaction decision rests on, so it belongs here verbatim rather
than paraphrased: an `agent_message` with `content: [A]`, followed by an
`agent_message_chunk` carrying `B`, yields `[A, B]`; a subsequent `agent_message`
with `content: [C]` **replaces both** and renders `[C]`. So:

| Update | Effect on the message with that `messageId` |
|---|---|
| whole-message, `content` omitted | content unchanged (other fields may still update) |
| whole-message, `content: null` or `[]` | cleared |
| whole-message, `content: [X]` | **replaces everything accumulated**, chunks included |
| `*_chunk` | appends |
| any update with a new `messageId` | a new message begins |

That third row is the load-bearing one. It is why compaction can correct a client's
view by re-sending affected messages (§9.2), and why replay-as-upserts converges a
client that already saw the chunk stream (§Session Setup) instead of duplicating it.
`ContentChunk` requires `messageId` **and** `content`; the whole-message forms require
only `messageId`, which is what makes "omitted means unchanged" expressible.

**The cancellation contract has an ordering MUST and a division of labor.** Agents
**MAY** send updates after receiving `session/cancel` but **MUST** do so *before* the
idle `state_update` — so `idle` + `cancelled` is strictly the terminator, and any
final tool or content updates come first. Two things are the **client's** job, not
ours: it SHOULD preemptively mark unfinished tool calls `cancelled`, and it MUST
answer pending `session/request_permission` requests with the cancelled outcome. We
still emit accurate terminal tool statuses — being correct is cheaper than reasoning
about which client did its part — but we do not block the `idle` on having done so.

**`requires_action` is not only about permissions.** The spec defines it as
"foreground work is blocked on user action," and permission is merely the common
case. Elicitation (§8) is the other one we have, and the pairing rule stands: enter
`requires_action` and release Router's per-model gate via `awaitingUser { }` at the
same moment, return to `running` on the answer. A turn that sits in `running` while
silently waiting on a person is the exact failure this state exists to prevent.

#### Tool calls — one plan error, one mapping trap

*(Audited 2026-07-28.)*

**Corrected in the row below: `subject: tool_call` carries a whole `ToolCallUpdate`,
not a `toolCallId`.** The plan said id. It is the full object — `title`, `kind`,
`status`, `content`, `locations`, `rawInput`, `rawOutput`. That is not pedantry, it
changes the design: because the permission request conveys the tool call's details
itself, **we can ask before emitting any `tool_call_update` for that call.** The
alternative reading forces an update first so the client has something to look up,
which would put a "pending" call in the timeline for something the user may reject.
Ask first, emit on approval.

**The mapping trap: `path` means opposite things for a rename.** ACP's diff change
uses two shapes — `DiffPathChange {path}` for `add` / `delete` / `modify`, and
`DiffPathPairChange {oldPath, path}` for `move` / `copy` — and ACP's `path` is
documented as **absolute, post-operation**: where the file ended up.
`FoundationModelsFileTool` models the same information the other way round:

| | source | destination |
|---|---|---|
| ACP `DiffPathPairChange` | `oldPath` | **`path`** |
| FileTool `FileChange` | **`path`** | `destinationPath` |

So a naive `path → path` mapping shows the *pre-rename* filename on every move and
copy, and does it silently — the diff renders, it is just wrong. Map
`FileChange.path → oldPath` and `FileChange.destinationPath → path` for those two
kinds only; `add` / `delete` / `modify` map `path → path` unchanged. This is a
translation note for this package, not an upstream ask: FileTool's shape is
self-consistent and correct on its own terms (`d7jwam5`).

**Smaller details worth not rediscovering:**

- **`status` defaults to `pending`** when a creating update omits it. So the first
  update for a call that is already running must say `in_progress` explicitly, or the
  client shows it queued.
- `ToolCallUpdate` requires **only** `toolCallId`; `title` SHOULD be on the first
  report, which is what makes the first update legible.
- `DiffChange` also carries optional `fileType` and `mimeType` — worth populating
  where the tool knows them, since it drives syntax highlighting in the client's diff
  view.
- `ToolCallLocation` requires `path`; `line` is optional (§7.3: `GrepMatch` supplies
  both).
- `PermissionOption` requires **all three** of `optionId`, `name`, `kind`.
- `RequestPermissionOutcome` has an `other` extension variant beyond `cancelled` and
  `selected` — treat an unrecognized outcome as a refusal rather than an approval.
- `status`, `kind`, `title`, `rawInput`, `rawOutput` are all
  `x-deserialize-default-on-error`: a malformed field degrades rather than failing the
  notification.

#### Content blocks — and a free win for the MCP bridge

*(Audited 2026-07-28. Lighter than the preceding sections; three things worth
recording.)*

**ACP's `ContentBlock` *is* MCP's**, and the spec says so outright: the protocol
"uses the same `ContentBlock` structure as the Model Context Protocol (MCP), enabling
agents to forward MCP tool outputs without transformation." That is a direct
simplification for §8.7's user-visible sink — mapping an MCP tool result's content
into `tool_call_update.content` is a **shape-preserving** move with no semantic loss
to reason about, not a translation with judgement calls in it. Two different Swift
types in two packages, so not literally zero code, but nothing to *decide*.

**`resource_link` is not capability-gated, so the decision the plan flagged now has a
sharper answer.** Every other rich variant is gated — `image` needs
`prompt.image`, `audio` needs `prompt.audio`, `resource` (embedded) needs
`prompt.embeddedContext` — but a `resource_link` may arrive no matter what we
advertise, carrying only `name` + `uri` (required) and optionally `mimeType`, `size`,
`title`, `description`, `icons`. **Decision: resolve `file://` URIs that fall inside
the session's root set through the `files` tool; report anything else unresolvable
and say why.** Refusing non-`file://` schemes is the *safe* answer as well as the
honest one — silently fetching an `http://` URI because it appeared in a prompt is a
request the user never made, from a process holding their credentials. `file://`
outside the root set is refused by `PathGuard` for the same reason it refuses any
other out-of-bounds path.

**Text is a MUST and everything else is ours to decline.** "All agents **MUST**
support text content blocks when included in prompts" — the one unconditional
obligation here. The gated variants stay absent until the roster can act on them
(§9.1), which is the honest-capability rule doing its job.

Field details worth not rediscovering: `TextContent` requires `text`;
`ImageContent` / `AudioContent` require `data` + `mimeType` (image additionally
allows an optional `uri`, audio does not); `EmbeddedResource` requires `resource`,
which is `TextResourceContents` (`text` + `uri`) or `BlobResourceContents` (`blob` +
`uri`). `Annotations` is not opaque — it carries `audience`, `priority`, and
`lastModified`, so it is safe to ignore on input but worth *populating* on output
where we know the answer.

#### Agent plan — full replace, not patch

*(Audited 2026-07-28. We emit nothing here (`plan_update` has no peer — §9.1), so
this is a note for whenever a planner lands, plus one protocol asymmetry worth
knowing.)*

**`plan_update` is the one update in v2 that replaces rather than patches.** Messages
upsert by `messageId`, tool calls upsert by `toolCallId` — but for plans, "agents
**MUST** transmit the complete entry list" and "clients **MUST** replace prior
contents entirely (not patch)." An implementer who has internalized the upsert
algebra from every other surface will get this exactly backwards and either lose
entries or duplicate them. `PlanEntry` requires **all three** of `content`,
`priority` (`high`/`medium`/`low`), and `status`
(`pending`/`in_progress`/`completed`/`cancelled`), each `_`-extensible. Multiple
concurrent plans are supported and distinguished by `planId`, which every variant —
standard, custom, or future — **MUST** carry.

#### Slash commands — the spec confirms our dispatch decision, and exposes one gap

*(Audited 2026-07-28.)*

**Confirmation: the agent parses the leading slash.** "Users include commands as text
messages in prompt requests using the slash prefix format (e.g. `/web agent client
protocol`). The agent recognizes and processes the command prefix accordingly."
There is no separate invoke method — a command arrives as ordinary prompt text — so
§6.2's "dispatch lives at the prompt owner" is not merely convenient, it is the only
place the protocol allows dispatch to happen. Note also that advertising is a **MAY**,
not a MUST: `available_commands_update` is optional, and the list may change at any
time during a session, which is what `commandUpdates` (§6.2) exists to feed.

**The gap: a command can arrive with other content attached.** "Commands can be
accompanied by other message content types simultaneously" — so a prompt may be
`[text("/deploy prod"), resource_link(...), image(...)]`. §6.2 says "a leading
`/name` routes through the registry" and stops there, which leaves the remaining
blocks undefined. Two cases, and they differ:

- **`.prompt` (and skill) commands expand into a model turn**, so the extra blocks
  ride along into that turn's prompt after the expansion. Dropping them would discard
  the file the user attached to the command they ran.
- **`.action` commands take no model turn at all**, so attached content has nowhere
  to go. Do not silently discard it — either refuse the invocation explaining that
  this command takes no attachments, or pass the blocks to the action and let it
  decide. Refusing is the safer default; silence is the one option that is wrong.

Field shapes: `AvailableCommand` requires `name` + `description`, with `input`
optional; `AvailableCommandInput`'s text variant requires `hint`. That `hint` is
where Skills' `argument-hint:` string lands verbatim (§6.3).

#### Elicitation, transports, extensibility — the last three

*(Audited 2026-07-28, completing the section-by-section pass.)*

**Elicitation: there are no generated types anywhere, and the docs disagree with the
schema.** Sharper than "unstable-only" — `elicitation/create` and
`elicitation/complete` appear in `acp-v2.meta.unstable.json` as **method names with no
`$defs` at all**, and neither file defines a single elicitation type. Meanwhile the
documentation shows `capabilities.elicitation: {form: {}, url: {}}` as a first-class
client capability, while the vendored stable `ClientCapabilities` carries **only
`_meta`**. That divergence is itself the finding: the docs are ahead of the schema we
generate from, so §8 stays `_meta`-negotiated and unstable-gated, and the shape may
move before it lands.

Three normative rules §8 was missing, all of which survive the gating because they
constrain the design rather than the wire:

- **"Agents MUST NOT fall back to form mode if URL mode is unavailable."** This is
  the tempting shortcut and it is explicitly forbidden — URL mode exists because the
  data is sensitive, and form mode is exactly where sensitive data must not go.
  Combined with "MUST use URL mode for sensitive data" and "MUST NOT send credentials
  over ACP," the only correct response to "URL unsupported" is to decline.
- **Clients MUST return `-32602` for an unsupported mode**, so a mode we should not
  have requested fails loudly and identifiably rather than hanging or half-working.
  Treat receiving it as our bug, not the client's.
- **`elicitationId` must be unique among *outstanding URL elicitations on that
  connection*** — a narrower scope than "globally unique" — and
  `elicitation/complete` **MUST** go only to the client that received the original
  request. With one connection per agent process this is easy to satisfy and easy to
  get wrong by keying on the session instead.

**Transports: the plan's stdout-purity rule is a protocol MUST, and the framing is
exactly what we assumed.** Messages are UTF-8 JSON-RPC delimited by `\n` and
**MUST NOT contain embedded newlines**; there is no content-length header. The agent
**MUST NOT** write non-ACP content to stdout, which is precisely the invariant §9.1's
gated integration test asserts — good to know that test is checking a MUST rather
than a house style. stderr is free for logging and the client may capture, forward,
or ignore it.

One thing worth noticing because it is not obviously ours to worry about: **batching
is permitted**, receivers MAY process batch entries concurrently and in any order,
and responses MAY come back in any order. But "initialize, auth, and session
operations **SHOULD NOT** be batched" — which covers essentially everything this
agent handles, so batch handling is the wire package's concern (§9.2) and never
becomes a sequencing hazard here.

**Extensibility: one rule bites us, and it is a good one.** `_meta` may be attached
to any protocol type, and root-level `traceparent` / `tracestate` / `baggage` are
reserved for W3C trace context — worth honoring if we ever emit tracing. The rule
that constrains us: **implementations MUST NOT add custom fields at the root level of
spec-defined types**, because "all possible root names are reserved for future
protocol versions." So every extension this plan contemplates — the elicitation
capability gate (§8), and anything we might have been tempted to hang off a session
or update — goes in `_meta`, never beside it.

And the rule that makes our `_`-prefixed status values legitimate rather than a
liberty: values beginning with `_` are reserved for implementation-specific
extensions, unknown non-underscore values are reserved for **future ACP variants**,
and implementations **MUST NOT** treat an unknown non-underscore value as a custom
extension. So MCP's `lost` outcome must ride as `_lost` (§8.7) — a bare `lost` would
be claiming a name the protocol has reserved for itself. When proxying, unknown values
**SHOULD** be preserved, and unknown variants **SHOULD** fall back to generic UI rather
than being dropped.

**Explicit peering — composition/runtime nouns ↔ ACP nouns.** The conformance
(`RoutedACPAgent`) is a
*translation, not a construction*: every ACP concept names its peer,
and anything with no peer is a capability switched off honestly, never faked.

*(Reconciled against the vendored `acp-v2.json` + `acp-v2.meta.json` on
2026-07-26. This table is the thing an implementer codes from, so it states the
**v2** surface — the stable method set is `initialize`, `auth/login`, `auth/logout`,
`session/new`, `session/resume`, `session/list`, `session/delete`, `session/close`,
`session/prompt`, `session/cancel`, `session/set_config_option`,
`session/request_permission`, `session/update`. `elicitation/*`, `mcp/*`, and
`session/fork` are **unstable-schema-only** and marked as such.)*

| ACP noun | Peer |
|---|---|
| the agent behind the connection | `RoutedACPAgent` over its `Router`. `initialize` negotiates `protocolVersion: 2` and reports `capabilities.session` (baseline `{}` at minimum) with the nested capabilities we actually implement: `prompt` (which content types — below), `mcp: {stdio: {}, http: {}}` (§8.7), `delete` (per §5's retention decision: advertised), `additionalDirectories: {}` (advertised — confinement is multi-root; see below and §7.1). **`capabilities` / `info`, not `agentCapabilities` / `agentInfo`** — v2 renamed both sides symmetrically. `authMethods` is absent/empty, which is what excuses us from `auth/login` + `auth/logout` |
| prompt content types (`capabilities.session.prompt`) | what the model can actually consume. Text always. `image` / `audio` / `embeddedContext` are advertised **only** if the roster can act on them — an honest `{}`-absent capability beats accepting an image and dropping it. `resource_link` is **not** capability-gated, so it arrives regardless: resolve `file://` inside the session root set via the `files` tool (§7.1), refuse every other scheme and every out-of-bounds path with a reason — declining to fetch an arbitrary `http://` URI is the safe answer, not merely the honest one |
| session (`sessionId`, `cwd`, `mcpServers`, `additionalDirectories`) | **one ACP session is one *root* Router session, and the ACP `sessionId` is that session's ULID** — the same identifier, not a mapping (§5). Forks and sub-agents are never ACP sessions. A `RoutedSession` composed per cwd — `session/new(cwd)` ⇒ per-cwd config layer + roster + instructions → `router.makeSession(...)`. `cwd` MUST be absolute, and the config layer, the §6.1 AGENTS.md walk, and the transcript location stay keyed off **`cwd` alone** — and `cwd` is now literally where transcripts are written (§5), which is why the spec's "MUST be an absolute path" and "MUST be part of the session's effective root set" are load-bearing rather than cosmetic. **`additionalDirectories` expands confinement only** — `PathGuard` gets the root set, `ShellPolicy` accepts those roots as valid working directories; every path absolute, invalid entries skipped-and-logged, order preserved. **`mcpServers` is no longer accepted-and-ignored** — it is connected before tools reach `makeSession` (§8.7) |
| `session/prompt` | **acknowledgement, not the turn.** v2's response is `{}`, returned immediately on acceptance. **Order matters and an earlier revision of this row had it backwards:** respond `{}` *first*, then emit `user_message`, then `state_update: running`, then the turn's output, then `idle` + `stopReason`. Emitting the notification before the response means a client can see an update for a prompt it has not yet had acknowledged. **The wire package supplies the primitive**: `AgentSideConnection.afterRespondingToCurrentRequest(_:)` defers work until the `{}` has gone out, so use it rather than a detached task that races the response. The handler dispatches slash commands (§6.2) before any of this. Echoing the prompt is a **MUST** — "the Agent MUST report where the user message was inserted in session history" — and that update is the source of truth for the agent-owned `messageId`; a `user_message_chunk` stream satisfies it equally. **One prompt per session at a time**: `idle` means "ready to process a new prompt," so a `session/prompt` arriving while not idle is a client error, not a queue — queueing stays composer-owned (§6.2), which is why Router's own prompt queue is deliberately not exposed over ACP |
| `state_update` (`running` / `idle` / `requires_action`) | **the turn state machine, and it needs a named owner in the conformance.** `running` on turn start; `requires_action` **whenever we block on the human** — around `session/request_permission` and around every elicitation round-trip (§8), paired with Router's `awaitingUser { }` so the per-model gate is released at the same moment the protocol says "blocked on user"; back to `running` on the answer; `idle` with a `stopReason` at turn end. Background work may continue while `idle` and its notifications do not change the state |
| `StopReason` | the turn's disposition: completed → `end_turn` ("no more work after the language model finishes responding without requesting more tools"), guardrail refusal → `refusal`, `cancel()` → `cancelled`, budget exhaustion → `max_tokens`, tool-loop cap → `max_turn_requests`. Extensible via `_`-prefixed values. **Catch the cancellation exception and map it** — the spec requires agents to "catch exceptions from aborted API calls and report the semantically meaningful `cancelled` stop reason"; a Swift `CancellationError` escaping as a JSON-RPC error or as `refusal` is the failure this names |
| `session/update` notification stream | Router's session event stream — full mapping table in §9.2. `ToolCallID` *is* the wire `toolCallId` (§6) |
| `session/cancel` (notification) | the session's cancel. v2 gives it a defined confirmation: respond to every pending permission request with the **cancelled outcome**, stop work, then emit `state_update` `idle` with `stopReason: "cancelled"`. There is no pending request to resolve any more. **Router's in-flight turn cancellation is still the gap** — a turn already handed to the model runs to completion, so today the honest report is "we stopped listening" |
| `usage_update` | `turnEnded(TokenUsage)` → `{used, size, cost?}` — the context meter, native (§9.2) |
| `available_commands_update` | the session's slash-command registry (§6.2) — published at session start and re-published whenever a source changes (skill discovered, template edited). v2 confirms our dispatch decision: clients invoke commands as **ordinary user-message text** in `session/prompt`, so dispatch must happen at the prompt owner. Extras' `argumentHint` maps to `AvailableCommandInput`, which requires a `type` discriminator — `{type: "text", hint: …}`; custom input types MUST begin with `_` |
| `session/list` | `TranscriptStore.sessions(inProject:)`. **`SessionInfo` needs more than the store currently promises** (§5): `sessionId`, `cwd` (required, absolute), `title` — optional in the schema (only `sessionId` + `cwd` are required), but we generate and persist one anyway; "may be auto-generated from the first prompt" — `updatedAt` (RFC 3339), and `additionalDirectories` as the **complete ordered** list (so order is persisted per session, not recomputed). Request params are `cwd` (filter) and `cursor`; the response carries `nextCursor`. **Cursor pagination is ours to implement**: opaque tokens, a bounded page size, an error on an invalid cursor. **Listable iff it is a root**: `parentId == nil` and `agentSpawn == nil` (§5), or a directory walk would surface forks and sub-agents as if they were conversations. Baseline — not capability-gated |
| `session_info_update` | title/metadata changing mid-session (e.g. the moment the first prompt yields a title) |
| `session/resume` (`replayFrom`) | Router restore. v2 folded `session/load` in. **The client sends `cwd` and it MUST match the original** — so validate the client's `cwd` against the one Router recorded at session creation and error on mismatch rather than silently re-rooting confinement; `additionalDirectories` is **authoritative and replaceable on every resume**: a non-empty list is the complete resulting root set, it may legitimately differ from the previous one, and omitted/empty means *no* additional roots — never inherit the session's former roots. `replayFrom: {"type":"start"}` replays before the response returns; omitted/`null` skips replay. **Replay emits whole-message upserts** (`user_message` / `agent_message` / `agent_thought`) reusing the original `messageId`s — **not** the `*_chunk` variants a live turn produces. `ReplayFrom` is an *inclusive cursor* whose `start` is one variant, so write the replay path parameterized by cursor rather than hardcoded to replay-everything. **Replay comes from Router's full recorded history** (the conversation the user actually had); **the live session is constructed from the newest compaction checkpoint** (the model's working transcript) — two different transcripts, deliberately. Restore reassembles this package's side (config layer, instructions, confinement) from the recorded cwd (Router board 6j4bven) |
| `session/close` | the agent drops the session from its bookkeeping. v2 makes this a **MUST**: cancel ongoing work **"as if `session/cancel` had been called"** — which carries cancellation's full semantics, so pending permission requests get the cancelled outcome and a `state_update` `idle` with `stopReason: "cancelled"` is emitted **before** the close response — then free resources: in-flight MCP calls, detached work, spawned stdio server processes, **and the session's descendants** — a running fork or in-flight sub-agent is this session's ongoing work, and leaving it burning a model gate after close is the failure this MUST exists to prevent (§5). Recording closed, transcript **retained** on disk |
| `session/delete` | **capability-gated (`capabilities.session.delete`); advertised, implemented as delisting** (§5, revised). The schema scope is narrow — "deleting an existing session **from `session/list`**" — and soft-vs-hard is explicitly not mandated, so we write a tombstone in `sessions.jsonl` and **leave `transcript.jsonl` on disk**: under §5 the transcript is committed source, and a picker affordance must not delete tracked files. Already-deleted / never-existent SHOULD succeed silently (a tombstone is naturally idempotent). Two implementation-defined behaviors, both decided: an active session is closed first (`session/close` semantics), and **resuming a deleted session errors** — a delete a later resume silently undoes is not a delete |
| session config options (`session/set_config_option`, `config_option_update`) | **now has a real peer, and it is Router's whole job.** v2 replaced modes with typed config options in categories `mode` / `model` / `model_config` / `thought_level`. `model` → the resident profile's slots (standard/flash) — profile and model switching finally gets a protocol-native surface. Fields are `configId`, `name`, `type` (`select` \| `boolean`), `currentValue`, `category`, and for selects an `options` array (`groupId` for grouping). A `set` returns the **complete** option list so dependent options can update; the agent may also push `config_option_update`. Every option MUST have a default so a client that ignores the feature still works. **The `session/new` and `session/resume` responses are where the list is first advertised** (both carry an optional `configOptions`), not just the `set` reply — so the selector must be constructible at session-creation time. **Day one ships one real option**, not an empty array: a `select` in category `model` over the resident profile's standard/flash slots — both already loaded, so it needs no upstream work and specifically not `kh01tv2`, which is only required to switch *profiles*. Array order is significant; `set` and the push both return the **complete** set, never a delta |
| `plan_update` | **no peer — off, stated honestly.** Router has no planning noun, and v2 only says agents *SHOULD* report plans. `PlanUpdateContent` is a tagged union whose every variant MUST carry a `planId`; entries are `{content, priority, status}`. If a planner ever lands (FoundationModelsAgents), this is its surface. We emit nothing, and we say so rather than leaving it unmentioned |
| `terminal_update` / `terminal_output_chunk` | `shell`'s byte-faithful display stream — **confirmed present in the vendored schema**; mapping in §8.6. Follow-up, not day one |
| `session/request_permission` | **has a peer in v2 and we need it** (§8.7): `destructiveHint` / `openWorldHint` gating on MCP tools, and Shelltool policy escalation. Shape is `{sessionId, title, options[≥1], description?, subject?}`. **`subject: tool_call` carries a full `ToolCallUpdate`, not a `toolCallId`** — so the request itself conveys title, kind, `rawInput`, and locations, and we can ask permission *before* ever emitting a `tool_call_update` for that call. `subject: command` is `{command, cwd}` required, plus optional `toolCallId` and `terminalId`. Note v2 **separated the prompt copy (`title`/`description`) from the structured subject**. `PermissionOptionKind` includes `allow_always` / `reject_always`, so **persisting always-decisions is this package's job** — it is the layer that owns config; the stacked `ShellPolicy` (§4) is the natural store, and the persistence scope (session / project / user layer) needs stating. Outcome is `cancelled` or `selected(optionId)` |
| `elicitation/create` / `elicitation/complete` | §8 — `ACPElicitationCoordinator`. **Unstable-schema-only**; see §8's revised prerequisite |
| `mcp/connect` / `mcp/message` / `mcp/disconnect` | `ACPTunnelTransport` (§8.7). **Unstable-schema-only** |
| `session/fork` | **unstable-schema-only, but note the peer exists**: Router already forks sessions. If it graduates, this is a cheap win rather than new machinery — do not build it against the unstable schema |
| `auth/login` / `auth/logout` | no peer — a local on-device agent has no auth. v2's rule is capability-shaped rather than method-shaped: return **no `authMethods`** and the obligation to implement either method disappears. (v2 renamed `authenticate` → `auth/login`, `logout` → `auth/logout`, and made both mandatory *only* when `authMethods` is non-empty; descriptors key on `methodId`, not `id`.) The `authRequired` error is never raised |
| `fs/*`, `terminal/*` (client-side) | **removed from the protocol in v2** — not "no peer," gone. Tools run in-process over the built-in trio (§7.1), which v2 says is the correct side of the protocol for them |
| session modes (`session/set_mode`, `current_mode_update`) | **removed in v2.** Superseded by config options above |
| `ClientCapabilities` | stable v2 defines **no standard client capability fields** — the type carries only `_meta`. So the client's job shrinks to rendering and answering prompts, and anything we want to know about a client (elicitation support, tunnel support) must be an `_meta` extension, negotiated as such |

Because ACP turns drive Router's sessions through the prompt owner,
everything the runtime owns works over ACP with zero ACP-specific code:
auto-compaction (proactive and reactive), chokepoint recording,
confinement, the context meter. Router's observable session state has no
peer — a frontend affordance ACP clients replace with their own UI — and
queueing stays composer-owned. (Name note: the wire package declares the
protocol-role `Agent`; nothing else here is named `Agent`, so
`RoutedACPAgent: Agent` reads unambiguously.)

Practical decisions:

- **The production CLI and the ACP agent are the same binary** — `<cli> acp` speaks
  ndJSON over stdio (stdout sacred, logs to stderr — §9.2's framing rules). One more
  reason the CLI stays thin: all three frontends are renderers over the same engine.
- **Multiple concurrent ACP sessions are supported from the start.** (Product v1 —
  not ACP v1; we target ACP v2 only.) One-resident-profile
  constrains *loaded models*, not session count: Router sessions keyed by
  `sessionId`, each with its own cwd-derived config layer, instructions,
  confinement, and transcript directory; turns serialize at the model's `serialGate`;
  recording stays per-session at Router's chokepoint.
  **Profile-collision policy — interim, and the interim is the wrong end state.**
  Today a project layer naming a different model than the resident profile logs a
  warning and keeps the resident model; the rest of the layer is honored. That is a
  stopgap, not the design: **per-project config means per-project profiles**, and a
  repo that pins a different coding model should get it. Two projects that name the
  *same* model must share one loaded copy rather than paying for it twice — GPU
  memory is the scarce resource, and duplicating a 32B model to serve two windows is
  the failure this has to avoid.

  The correctness constraint underneath is sharper than the optimization: **the
  memory budget must have exactly one authority.** Two Routers each running Router's
  joint-fit against the whole machine budget will each independently conclude they
  can afford a large model, and together they will exhaust it. So model residency
  has to be pooled and reference-counted with a single evictor, whether that is one
  Router holding several profiles or several Routers borrowing from a shared pool.
  Encouragingly, the piece that would be hardest to retrofit is already right:
  Router's `generationGate` lives on the **model** (`LanguageModelProfile`), not on
  the Router, precisely because "MLX generation runs a single GPU stream and is not
  safe to interleave" — so a shared model already carries the gate that keeps two
  borrowers from interleaving on it. Router's existing
  `slotMembership(profile:) -> [ModelRef: Set<ModelSlot>]` is the same dedupe one
  level down, and is the precedent to generalize.

  Filed upstream as Router **`kh01tv2`** — and **it has landed** (2026-07-28), so the
  stopgap is retired: per-project profiles are now implementable. Router's
  `PooledResidencyTests` covers the cases that matter here — two profiles sharing a
  `ModelRef` load one instance, disjoint profiles are both resident when the union
  fits, a union that would exceed the budget **fails cleanly rather than exhausting
  memory**, a shared model unloads only once both profiles release it, concurrent
  generation over one resident model never overlaps, and the same repo at two
  revisions deliberately does *not* share. Single-profile callers are unaffected. Gate waits are `Task`-cancellation-aware, so a
  queued session's `session/cancel` never outwaits another session's turn.
- **`additionalDirectories` is supported: we advertise the capability and confine
  multi-root.** *(Decided 2026-07-26, reversing an earlier "ship single-root, capability
  absent" recommendation. The use case is ordinary — a monorepo beside a vendored
  dependency, a repo beside its generated-SDK sibling — and `PathGuard` is gaining a
  root set upstream.)* This is **not a passthrough field**: accepting it while
  confining to cwd alone would reject every tool call outside the primary root, which
  is worse than not advertising at all. What it means concretely:

  - `initialize` reports `capabilities.session.additionalDirectories: {}` (an object
    marker; omitted or `null` both mean unsupported).
  - `session/new` and `session/resume` carry `additionalDirectories: [AbsolutePath]`.
    Every path MUST be absolute. The schema marks the array
    `x-deserialize-skip-invalid-items`, so a malformed entry is skipped rather than
    failing the request — log it, don't reject the session.
  - **The roots expand the workspace scope without changing `cwd`.** The spec is
    explicit that `cwd` "remains the base for relative paths," and that stays true of
    everything else keyed off it here: the config layer (§4), the AGENTS.md walk
    (§6.1), and the transcript directory (§5) are all **cwd-only and stay singular**. A
    vendored dependency you can read is not a project whose `AGENTS.md` governs you,
    and a second root must never fork the transcript location. Confinement is the
    only thing that becomes plural.
  - **On resume the list is authoritative and replaceable, not sticky.** Per the
    schema: a non-empty list "is the complete resulting additional-root list for the
    resumed session," it "may differ from any previously used or reported list as
    long as the request `cwd` matches," and omitted or empty means **no additional
    roots are activated**. So a resumed session does not inherit its old roots — we
    rebuild confinement from exactly what the resume request carries, every time.
    Getting this wrong in the lenient direction (silently keeping yesterday's roots)
    would quietly re-widen a boundary the client just narrowed.
  - **The list is ordered**, and `SessionInfo.additionalDirectories` must report "the
    complete ordered additional-root list." So order is persisted per session, not
    recomputed from a set (§5).

  Upstream: **`FoundationModelsFileTool` task `939nnzx`** (multi-root `PathGuard`) is
  the only blocking dependency, and it is in progress. **`FoundationModelsShelltool`
  needs nothing here** — it is not root-confined in the first place (see §7.1), so
  there is no boundary to widen.
- **Tools stay in-process — and v2 turns this from a risk into the sanctioned
  design.** v1 routed file access and execution through the client (`fs/*`,
  `terminal/*`), which made our direct filesystem and subprocess access unusual for
  an in-editor ACP agent — recorded then as an accepted risk. **v2 removed all seven
  of those client methods** and tells agents to do their own file access and their own
  execution, with MCP as the standard route. So the built-in trio (§7.1) is now on the
  side of the protocol v2 says it belongs on, and the `ToolContext` seam no longer
  needs to anticipate an ACP-backed filesystem — that surface does not exist to back
  onto. What remains genuinely ours is the confinement story, unchanged and now
  load-bearing rather than mitigating: `PathGuard` bounds `files`, the stacked
  `ShellPolicy` bounds `shell`, and `session/request_permission` (§9.1) is how the
  user is asked before either exceeds it.
- **stdout purity is tested, not assumed.** The `shell` tool runs subprocesses
  in-process while stdout must carry nothing but ACP frames; a gated integration
  test runs `<cli> acp`, executes a real shell-tool turn, and asserts every stdout
  byte parses as ndJSON (§10).

**Superseded: the `SessionProvider` design** — an external bridge driving the
inner bare session through a provider (factory + store hooks + `onTurnEnded`
sync). It failed on four counts, all symptoms of attaching an application
protocol at the model layer: a **stale session** after every compaction swap
(the session was handed over by value, once); **compaction never triggering**
on ACP turns (fill check and retry live in the runtime session); a bolt-on turn-end
recording hook; and history replay (v1's `session/load`, now `session/resume`)
**replaying the compacted transcript** instead of the user's real history. All four dissolve with the agent-level
conformance; none of the provider machinery gets built.

This landed, and it landed our way: v2 makes `session/list` / `resume` / `close`
**baseline** — mandatory for any agent supporting sessions, not capability-gated —
and folded `session/load` into `session/resume` with `replayFrom`. What was a
tailwind in the RFDs is now settled in the vendored schema. The upshot is that the
session model the peering table already provided (`TranscriptStore` + Router's
checkpoint-aware restore) is the one v2 requires, so none of it is optional and
none of it is speculative. The corollary cuts the other way too: **"capability
off" is not available for list/resume/close.** They must work.

### 10.1 The test ladder — five tiers, and only two of them need a model

*(Designed 2026-07-29. The organizing question: **"do the tools work" and "does the
model use the tools" are different questions**, and conflating them is what makes
integration suites slow, flaky, and gated into irrelevance. Only the second needs a
model.)*

| Tier | Model | Client | Tools | Gated | Answers |
|---|---|---|---|---|---|
| 0 — unit | — | — | — | no | do the tools work in isolation *(**done**: FileTool 461, Shelltool 298, Router 624)* |
| 1 — golden conformance (`78sq1kx`) | scripted | recording sink | fake | no | is the wire shape right — ordering, upserts, replay |
| 2 — **tool integration (`42qaxpc`)** | scripted | recording sink | **real** | no | do real tools work through the real conformance |
| 3 — stdio contract (`yxj21nw`) | scripted | subprocess | real | yes | does framing survive a real process boundary |
| 4 — eval (`hhzwwz2`) | **real** | in-process | real | yes | does the model *choose* to use tools, and succeed |

**There is no "fake client" to build, because `ClientSideConnection` is the client.**
That is worth stating plainly, since it is the thing people assume they must write and
then never do. The wire package's own tests show the shape — a `Client` conformance is
roughly ten lines:

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

That is a **sink**, not a simulation: it records notifications and answers permission
with a scripted decision. Nothing renders, nothing pretends to be a person. Everything
above tier 0 uses the same ten lines.

**Tier 2 is the missing piece and the one that answers the question.** Real
`ToolCatalog`, real `FileTool` and `Shelltool`, real `RoutedACPAgent`, real
`session/new(cwd)` against a temp directory — with the *model* scripted. The seam is
already public: inject a `ModelLoader` whose `LoadedLLMContainer.makeSession` returns a
`LanguageModelSessionBackend` that emits a predetermined tool call. Router's own tests
do exactly this (`ScriptedOverflowBackend`), so the pattern is proven and needs no
upstream change. No MLX, no download, no Apple-silicon gate — it runs in CI on every
commit.

What tier 2 proves that no other tier does:

1. **Composition** — `ToolCatalog` constructs each tool with the right `ToolContext`:
   the root set derived from `cwd` + `additionalDirectories`, and that tool's decoded
   config section.
2. **Confinement through the protocol** — `session/new(cwd)` actually bounds
   `PathGuard`. Ask the `files` tool for a path outside the root set and get a refusal,
   driven from the client end rather than by constructing a guard directly.
3. **Projection** — a real tool call becomes a correct `tool_call_update`: stable
   `toolCallId` across its lifetime, `in_progress` → `completed`, populated
   `locations`, `rawInput`/`rawOutput`, and the `title` on first report.
4. **Turn ordering** — `{}` → `user_message` → `running` → tool updates →
   `idle(end_turn)`, in that order (§9.1).
5. **Enable/disable** — `shell: false` in the project config means no shell tool
   reaches the session, verified from the client end.

**The rule that makes tier 2 trustworthy: assert the filesystem, never the
transcript.** If the test says a file was written, `read` it from disk and compare —
do not believe a `tool_call_update` that claims success. This is the same discipline
§10.3's evaluators use ("mechanical, re-verified outside the agent"), and it is what
separates a test that catches a broken tool from one that only catches a broken
*report* of a tool.

**MCP gets tier-2 coverage for free**, once `4egfvw3` lands: `FoundationModelsMCP`
already ships `MCPTestServerCLI` and a `ScriptedServer`, so the `mcp` built-in can be
exercised against a real server process rather than a mock — spawn it, list its tools,
call one, and assert the `tool_call_update` correlation holds.

**Tiers 3 and 4 stay gated, and stay small.** Tier 3 exists for exactly one thing a
tier-2 test cannot see: real process boundaries — stdout carrying nothing but ndJSON
while `shell` runs subprocesses that write to *their* stdout, and messages containing
no embedded newlines (§Transports, both protocol MUSTs). Tier 4 is the eval below.

### 10.2 `Examples/acp-agent` — the example program, and the tier-3 fixture (`w7pce78`)

**One executable serves both purposes, deliberately.** The family convention is an
`Examples/` directory of runnable programs (Router and MCP both ship one), and the
example this package owes is the obvious one: **how do I build an ACP server CLI on
top of this?** That is also precisely what tier 3 needs to spawn. Writing it twice
would guarantee the example rots while the fixture stays green.

`Examples/acp-agent/main.swift`, and it should stay small enough to read in one
sitting — the composition is the lesson:

```swift
// 1. the dotfolder name is the frontend's choice (§4) — everything else derives
let agent = try await RoutedACPAgent(name: "acp-agent", workingDirectory: cwd)

// 2. serve ACP over stdio; stdout is sacred, logs go to stderr
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in agent }
await connection.run()
```

What the example must demonstrate, because these are the questions a reader actually
has: choosing the dotfolder name and what it controls; serving over
`AgentSideConnection(stream: .stdio)`; **logging to stderr only**; and where a frontend
would add its own tools to the merged roster (§7.1). What it must *not* grow into is a
second product — no argument parsing beyond what stdio serving needs, no rendering, no
config wizardry. The production CLI grows in its own repo from a copy of this (§9).

#### Streaming is the part that is easy to get wrong

ACP over stdio is **full duplex, not request/response**, and v2 makes that unavoidable
rather than optional: `session/prompt` returns `{}` immediately and the entire turn —
`user_message`, `running`, every `agent_message_chunk` and `tool_call_update`, then
`idle` — arrives afterwards as notifications on the same pipe the connection is still
reading requests from. An example written as a read-request / write-response loop
would deadlock the moment it tried to emit an update mid-turn, so the shape matters
pedagogically as much as functionally.

Three things the wire package already handles, worth knowing so the example does not
reinvent them:

- **Frame serialization.** `StdioTransport`'s write "runs under a lock, so overlapping
  calls from the connection actor's reentrant methods serialize into non-interleaved
  frames." Concurrent sessions emitting updates simultaneously cannot produce a torn
  line — exactly the corruption that would otherwise stay invisible until some client
  failed to parse.
- **Respond-then-notify ordering.**
  `AgentSideConnection.afterRespondingToCurrentRequest(_:)` is the primitive §9.1's
  prompt row requires: it defers work until *after* the `{}` has gone out, which is how
  "respond first, then emit `user_message`" is achieved without racing. Use it rather
  than spawning a detached task and hoping.
- **Lifecycle.** The client launches the agent as a subprocess and terminates it; the
  agent reads until stdin EOF. There is no teardown handshake to implement.

**The one hazard the example must actively defend against is subprocess stdout.**
`shell` spawns children, and a child that *inherits* the agent's stdout writes its
output directly into the ACP frame stream — silently corrupting it in a way no unit
test would catch, because the tool itself behaved correctly. Shelltool captures child
output rather than inheriting it (§7.1), and tier 3 exists to prove that end to end:
run a real shell turn through the real binary and assert every byte of stdout parses as
ndJSON. That is a protocol MUST ("the agent MUST NOT write non-ACP content to stdout"),
not a house rule.

The wire package's `acp-test-agent` is the precedent and the contrast: it answers
`initialize` and nothing else, existing purely for transport tests. Ours composes the
real runtime and real tools, which is why it doubles as the tier-3 fixture rather than
being a third thing to maintain.

### 10.3 Evaluations — `PythonCLIEvaluation` (end-to-end coding agent)

*(This eval drives real `files` + `shell` tools, which the runtime may never
name — Router keeps the compaction-focused eval over sample tools (Router
board 4ce0a1k); the end-to-end coding eval belongs to the layer that
composes the roster.)*

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

