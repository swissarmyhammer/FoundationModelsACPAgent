# CLI Plan

This plan adds a command-line frontend to the composed agent. It stands
on its own. It cites `plan.md` for the rules that it keeps, and it states
its own rules where the two differ. `plan.md` does not change.

Two sibling plans go with it:

- `FoundationModelsACPClient/cli-plan.md` — the `acp-client` binary.
- `FoundationModelsExtras/doctor-plan.md` — the `Doctorable` protocol
  that §6 builds on.

## 1. Purpose

We want a headless CLI. You give it a prompt. It runs one turn. It prints
the answer and it exits. The CLI is an ACP client, and the composed agent
of this package is the ACP agent. The two speak the protocol in every
mode.

It must be as good to use as a well-made Rust CLI: real progress while
the model downloads, a `config` command that shows what is in effect, and
a `doctor` command that says what is wrong and how to fix it.

## 2. The binaries

| Binary | Package | Job |
|---|---|---|
| `acp-agent` | this package | The product. A headless CLI, and an ACP server. |
| `acp-print` | this package | The tier-3 fixture. One prompt, no flags. It does not change. |
| `acp-client` | `FoundationModelsACPClient` | A client for any ACP agent. It tests our server mode. |

`acp-agent` keeps its name. The name already roots the configuration
stack (`$XDG_CONFIG_HOME/acp-agent/` and `<cwd>/.acp-agent/`), so the
binary and its dotfolder agree.

## 3. Why one binary, and not a server

A separate server process is only of value if it shares the memory of a
loaded model between clients. A stdio agent cannot share it: the client
starts the agent, and the agent dies with that client. So a stdio-only
split gives a second process and no benefit.

stdio keeps a different value: **interop**. Zed and other ACP clients
start an agent as a subprocess and speak ndJSON on its pipes. That is the
only way they connect to us. So we keep the server mode, but we stop
treating it as the fast path.

A shared model needs a long-lived agent, and a socket. §11 holds that
work. HTTP is not in this plan. See §11.3.

## 4. The modes

| Mode | Command | Transport |
|---|---|---|
| CLI | `acp-agent run "<prompt>"` | `InMemoryTransport.pair()`, in one process |
| Server | `acp-agent acp` | ndJSON on stdin and stdout |
| Shared server | `acp-agent serve` | A unix socket. Later, and only if §11.1 shows a cost. |

**The one architecture rule:** the CLI reaches the agent through an ACP
connection in every mode. Only the transport changes. The CLI must never
call `RoutedACPAgent` directly. If we break this rule, the `serve` mode
of §11 becomes a rewrite, and the CLI stops proving the protocol.

The in-process mode uses the method that the Mac app uses (`plan.md`
§19): `InMemoryTransport.pair()` binds an `AgentSideConnection` to a
`ClientSideConnection` with no pipe and no subprocess.

## 5. The command-line surface

### 5.1 The parser

Both new binaries use **swift-argument-parser**. We write no parser of
our own. The library gives `--help`, `--version`, the subcommand tree,
and the usage errors, and we would otherwise write each of them twice.

It costs no new package checkout. `FoundationModelsExtras` already
declares `apple/swift-argument-parser` from 1.8.0, and this package
already depends on Extras, so the library stands in `Package.resolved`
today. This package declares `apple/swift-argument-parser` directly,
with the same version floor, because it wants the parser only and not the
`Operations` fusion machinery that re-exports it.

`acp-print` does not change. It parses one argument by hand, and its
no-flag rule is what makes it a proof.

### 5.2 The terminal output

The bar is a good Rust CLI. That stack is clap, indicatif, dialoguer,
comfy-table and owo-colors. The Swift map:

| Rust | Swift |
|---|---|
| clap | swift-argument-parser (§5.1) |
| indicatif, dialoguer, comfy-table, owo-colors | **Noora** (Tuist) — one CLI design system: spinners, progress, prompts, tables, alerts |

**We adopt Noora.** No package in the family uses a terminal UI library
today, so this sets the family precedent, and the client CLI follows it.

One rule keeps the choice reversible: **`TerminalRenderer.swift` is the
only file that imports Noora.** It vends a spinner, a progress bar and a
table, and nothing more. The download progress, `doctor` and `config
path` all call that type. If Noora ever disappoints, the swap costs one
file. A test pins the single import.

The renderer obeys §5.6 and §5.7 without exception: it writes to
**stderr** only, and it draws nothing at all when stderr is not a
terminal. It takes its destination as a `FileHandle`, so a test injects
a `Pipe` and asserts zero bytes.

### 5.3 The subcommands

```
acp-agent run <prompt>       Run one turn. Print the answer. This is the default.
acp-agent acp                Serve ACP on stdin and stdout.
acp-agent config show        Print the merged configuration, and where each value came from.
acp-agent config init        Write a config.yaml with every key at its default.
acp-agent config path        Print each layer path, and say which ones exist.
acp-agent config edit        Open the nearest config.yaml in $EDITOR.
acp-agent instructions eject Write Instructions.md into a layer (plan.md §3.1).
acp-agent doctor             Check that this configuration will actually work.
acp-agent --help             Print the usage to stdout, and exit 0.
acp-agent --version          Print the version to stdout, and exit 0.
```

`run` is the **default subcommand**, so `acp-agent "write a haiku"` runs
a turn. The parser matches the first argument against the subcommand
names first, so a prompt that is exactly a subcommand name would select
that mode instead. The explicit form resolves it:

```
acp-agent run doctor         The prompt "doctor". Not the check.
```

**The script rule:** a script always writes the subcommand. A prompt that
comes from a variable can hold any word, and `acp-agent run "$PROMPT"`
can never surprise it. The short form is for a person at a keyboard.

`serve` joins this list only if §11.1 shows a cost.

### 5.4 The options of `run`

| Option | Effect |
|---|---|
| `--cwd <path>` | The working directory. It roots the dotfolder stack and the session. Default: the process working directory. See §5.10. |
| `--resume <session-id>` | Continue an existing session with `session/load`. Default: a new session. `--cwd` with `--resume` is a usage error: the stored session already has a working directory, and it wins. |
| `--out-of-process` | Start a second copy of this binary in `acp` mode, and speak over stdio. It tests the wire path. |
| `--verbose` | Write the session events to stderr. See §5.7. |
| `--quiet` | Draw no progress and no decoration, in a terminal too. See §5.7. |

**The flag rule:** a setting that `config.yaml` already holds gets no
flag. `plan.md` §2.2 makes the configuration derived, and a flag for the
same value gives two sources of truth. The profile, the tool roster, the
transcript location and the compaction limits stay in the file. `config
edit` is how you change them, and that is one keystroke more than a flag.

`--cwd` is the one exception in appearance only. It does not carry a
configuration value. It selects **which** stack the loader reads, so the
CLI applies it before it loads `config.yaml`.

### 5.5 Where the prompt comes from

In `acp` mode **stdin is the wire**. That mode never looks at stdin for a
prompt.

In `run` mode:

| Condition | Result |
|---|---|
| A prompt argument | Use it. |
| No prompt, and stdin is a pipe or a file | Read the prompt from stdin. |
| No prompt, and stdin is a terminal | Print the usage to stderr. Exit 2. |
| The prompt is `-` | Read the prompt from stdin, a terminal included. |

This gives `echo "hello" | acp-agent`, which is what a person expects.

### 5.6 stdout

- Write each `agent_message_chunk` as it arrives, and flush it. A local
  model is slow, so a person must see the answer grow.
- Write the text **verbatim**. Add no trailing newline, and add no color,
  in a terminal and in a pipe alike. The output is data, and a rule that
  changes with a terminal cannot be tested byte for byte.
- stdout gets nothing more. Not a session id, not a token count, not a
  stop reason.
- The exceptions are the reporting subcommands, whose report **is** their
  output: `config show`, `config path`, `doctor --json`, `--help` and
  `--version` write to stdout.

In `acp` mode the older contract applies: stdout carries ndJSON frames
only, and a shell child never inherits stdout (`plan.md` §17).

### 5.7 stderr, and the download problem

The default profile is large, and nothing is on disk on a clean machine.
So the first `acp-agent run "hello"` downloads gigabytes. A person who
asks for a haiku and gets a silent terminal for ten minutes will conclude
that the tool is broken. **Progress is not decoration here. It is the
difference between working and appearing hung.**

Router already does this work, so we build almost nothing:

- `ResolutionProgress` carries the `phase` (`sizing`, `downloading`,
  `loading`, `ready`, `failed`), an overall `fraction`, and per-slot
  `bytesDownloaded` and `bytesTotal`.
- `RoutedACPAgent.init` already takes `reporting: ResolutionProgress?`.

**One upstream change is necessary.** In Router, only `phase` is public.
`fraction` and `slots` are internal, so a CLI outside Router cannot draw
a bar. `ResolutionProgress.swift` must make them public. That is the one
blocking dependency of this plan outside the two CLI repositories.

The rules:

| Condition | stderr shows |
|---|---|
| stderr is a terminal | The resolution progress: the phase, the slot, and a bar with the bytes. Then the running tool name on one line, rewritten in place. |
| stderr is a pipe or a file | Nothing, until something fails. |
| `--verbose` | The session events, one line each: the tool calls, the plan updates, the stop reason. In a pipe too. |
| `--quiet` | Nothing but errors, in a terminal too. |

The progress is drawn only for the resolution, and it is erased when the
first answer chunk arrives. §5.6 stays byte-exact in every case, because
none of this touches stdout.

### 5.8 Exit codes

"Nonzero" is not enough for a script. Both binaries share one table:

| Code | Meaning |
|---|---|
| 0 | `end_turn`, or a report that ran |
| 1 | An error: configuration, spawn, protocol, or I/O. `doctor` found an error. |
| 2 | A usage error |
| 3 | `refusal` |
| 4 | `cancelled` |
| 5 | `doctor` found warnings, and no error |
| 124 | A timeout, which is the `timeout(1)` convention |

Code 5 exists because the Rust doctor's code 2 for errors would collide
with our usage error. See `doctor-plan.md` §5.

### 5.9 Interrupt

`Ctrl-C` must not kill the process. The CLI sends `session/cancel`, waits
for the `cancelled` stop reason, prints the text that arrived, and exits
4. A second `Ctrl-C` ends the process at once.

During a download, the first `Ctrl-C` stops the resolution and exits 4.
A partly downloaded model stays in the Hugging Face cache, so the next
run continues rather than starting again.

This matters most with `--out-of-process`, and in `acp-client`. A hard
kill of the client leaves a model process that holds gigabytes.

### 5.10 Where the configuration comes from

The CLI adds no configuration mechanism. It reads the stack that
`plan.md` §2.2 already gives, through `ConfigurationLoader`. The layers,
with the lowest precedence first:

| Layer | Path | On disk? |
|---|---|---|
| 1. Builtin defaults | none | **No.** The property defaults of `AgentConfiguration` are the defaults. Nothing is written on the first run. |
| 2. User | `$XDG_CONFIG_HOME/acp-agent/`, or `~/.config/acp-agent/` when that variable is not set or is not absolute | Yes. No leading dot, because `~/.config` is already hidden. |
| 3. Project | `<project>/.acp-agent/` | Yes. A leading dot, because it sits at a repo root beside the source. |

Each layer holds `config.yaml` (key-level override), `Instructions.md`
(wholesale replace, nearest layer wins), `AGENTS.md` (additive, the user
layer first), and `_partials/`.

**There are two loads, and they use different directories.**

| Load | Keyed by | Why |
|---|---|---|
| At process start | The process working directory | It resolves `profile`, so the agent can build the Router and load the model. |
| Per session | `session/new(cwd)` | `plan.md` §2.2: one process serves many sessions in different repos, so two sessions can correctly see different project configuration. |

So `--cwd` behaves differently in each mode:

- In `run` mode the two collapse into one directory. `--cwd` sets both:
  the stack the process reads at start, and the `cwd` that the CLI sends
  in `session/new`.
- In `acp` mode there is **no `--cwd`**. The client gives the working
  directory with each session, and the agent obeys it. A flag there would
  fight the protocol.

**A note on the defaults layer.** `DotfolderStack` builds its override
key as `<NAME>_DEFAULTS_DIR`, and our name gives
`ACP-AGENT_DEFAULTS_DIR`. A shell cannot `export` a name that holds a
hyphen, so only `env 'ACP-AGENT_DEFAULTS_DIR=…' acp-agent …` reaches it.
This package passes no defaults directory, so layer 1 stays code, and the
key is not used today.

### 5.11 The `config` subcommands

Nothing is on disk after an install, so the configuration is invisible.
These four commands make it visible and editable. None of them adds a
setting: they show and they write the stack of §5.10.

| Command | Behavior |
|---|---|
| `config show` | Print the merged configuration as YAML to stdout. With `--source`, annotate each key with the layer that set it. `--json` prints the same tree as JSON. |
| `config init` | Write `config.yaml` with every key at its default, each under a comment that says what it does. `--user` writes the user layer, `--project` the project layer; `--project` is the default. It refuses to overwrite an existing file unless `--force` is given. It prints the path it wrote. |
| `config path` | Print each layer path, one per line, with a mark for the ones that exist. |
| `config edit` | Open the nearest `config.yaml` in `$EDITOR`. With no file, it runs `config init` first and says so. |

`config show --source` is the important one. `LayeredYAMLDocument`
already returns source data for every key, so the output can say **which
layer won each value**. That is the question a person actually has, and
nothing answers it today.

`config init` and the `/config export` slash command (`plan.md` §14.1)
call one implementation. Two front doors, one behavior.

### 5.12 The `doctor` subcommand

`doctor` answers one question: will this configuration actually work? It
prints a table of named checks, each with a status, a message, and — for
anything that is not `ok` — the command that fixes it.

The protocol, the runner and the plain renderer are in Extras. See
`FoundationModelsExtras/doctor-plan.md`. This package writes the checks,
as `Doctorable` conformances:

| Component | Checks |
|---|---|
| Configuration | It loads. Every warning is listed. Each layer path exists, is readable, is writable. |
| Profile | Each model reference is well formed. Each one resolves at Hugging Face. The trio fits this machine's memory. The free disk covers what must still be downloaded. A slot that names an MTP model gets a warning, because Router does not use the MTP head (§7.1). |
| Transcripts | The transcript directory exists, or its parent is writable. |
| Sandbox | The seatbelt sandbox starts. Each `extraWritePaths` entry exists. |
| Tools | The shell store directory is writable. Each configured MCP server starts, or its URL answers. |
| Skills | The skills stack is found. |
| Runtime | The Metal shader library stands beside the binary. |

The first two rows earn the command on their own. A wrong model
repository id and a profile that does not fit the machine are the two
failures a person cannot diagnose from the error that Router raises.

`doctor` exits 0, 1 or 5 (§5.8). `--json` writes the report to stdout for
a script.

## 6. `acp-client`

`acp-client` is in the client package, and not in this one. It drives any
ACP agent, so it must not know this package. It links the client package
and the wire only.

**The client package owns this binary.** Its own `cli-plan.md` holds the
full specification, the tests and the milestones. This section gives the
part that this package depends on. If the two differ, the client plan
wins.

```
acp-client run <prompt> -- <agent-command> [agent-args...]
acp-client probe -- <agent-command> [agent-args...]
acp-client doctor -- <agent-command> [agent-args...]
```

Everything after `--` is the agent command, with its own arguments. The
separator means that `acp-client` never splits a command string into
words, so no quoting rule can go wrong.

It obeys §5.5 to §5.9 without change. It adds `--frames`, which writes
every ndJSON message to stderr in both directions. That option is the
reason the binary exists: it shows the protocol exchange, so a person can
see what an agent sent. `acp-print` cannot do this, and it must not learn
to.

The test loop is then:

```
acp-client run "write a haiku" --frames -- acp-agent acp
```

## 7. The default configuration

`plan.md` §2.2 fixed the defaults at a profile that runs on a 16 GB
machine. This plan replaces that, because the old models are out of date:

| Key | Old default | New default |
|---|---|---|
| `profile.standard` | `mlx-community/Qwen2.5-14B-Instruct-4bit` | `mlx-community/Qwen3.8-27B-4bit` |
| `profile.flash` | `mlx-community/Qwen2.5-3B-Instruct-4bit` | `mlx-community/Qwen3-4B-4bit` |
| `profile.embedding` | `mlx-community/bge-small-en-v1.5-4bit` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |
| The memory floor | 16 GB | **32 GB** |

The floor moves because it must. A 27B model at 4 bits is about 15 GB on
its own, and Router's `JointFit` prices the whole trio against the
budget. On a 16 GB machine the resolution would fail, and the failure
would look like a bug.

**Two consequences:**

- The `doctor` memory check of §5.12 is not a nicety. It is how a person
  on a 16 GB machine learns the reason in one line instead of reading a
  resolution failure.
- `README.md` and `plan.md` §2.2 both state the 16 GB figure. They are
  now wrong. This plan does not edit them; §12 records the difference.

### 7.1 No MTP model is a default, and here is why

**Decision: no slot names an MTP model until Router uses the MTP head.**
An MTP repository carries a draft head beside the weights. Router never
reads that head, so the default would download bytes that do nothing.
That is the wrong trade for a first run, and it is why `flash` is
`Qwen3-4B-4bit` and not `Qwen3.5-9B-MTP-4bit`.

The rest of this section records what we found, so the decision can be
reversed the moment Router changes.

Multi-token prediction is speculative decoding: a small draft head
proposes several tokens, and the target model verifies them in one pass.

**`mlx-swift-lm` implements it, and the implementation is complete:**

| File | What |
|---|---|
| `MLXLMCommon/MTPDrafterModel.swift` | The drafter protocol, and the shared K/V threading |
| `MLXLMCommon/MTPDrafterModelFactory.swift` | Loads a drafter from a model directory |
| `MLXLMCommon/MTPSpeculativeTokenIterator.swift` | The speculative loop |
| `MLXLMCommon/Evaluate.swift:2225, 2262` | `generate(…, mtpDrafter:, blockSize:)` |
| `MLXLLM/Qwen35TextMTPRegistration.swift` | Registers drafters for `qwen3_5` and `qwen3_5_moe` |

It is mature: if the target stops emitting drafter state, the iterator
logs once, reports a `passthroughReason`, and finishes with ordinary
generation. The default `blockSize` is 4, matching mlx-vlm.

**Router does not use any of it.** A search of
`FoundationModelsRouter` for `MTP`, `speculat`, `drafter` and `draft`
returns nothing. This package returns nothing either. Router calls the
plain generate path, with no drafter of any kind.

So an MTP model **works**, and it gives no speedup.
`LLMModelFactory.swift:70` registers `"qwen3_5"` to `Qwen35Model`, so the
base weights load through the ordinary path. The MTP head downloads with
them and is never read. Nothing breaks; we pay for bytes we do not use.

Three things would make it real, and all three are upstream in Router:

1. Load the drafter through `MTPDrafterModelFactory.shared`, beside the
   target model.
2. Call `generate(…, mtpDrafter:, blockSize:)` in place of the plain
   entry point.
3. Let a profile say a slot is MTP-capable, and fall back cleanly when it
   is not.

No default names an MTP model, so nobody pays this cost without asking
for it. A person **may** still configure one, so the `doctor` profile
check (§5.12) reports a warning when a slot names an MTP model: the
runtime does not use its MTP head. A person must not believe they have
speculation that they do not have.

When the three steps above land in Router, this decision reverses in one
line: the `flash` default becomes `mlx-community/Qwen3.5-9B-MTP-4bit`,
and the doctor warning becomes an `ok` row.

### 7.2 The rest of the defaults

Every other default keeps its value, and §5.10 gives the full list. One
of them is worth stating here, because it interacts with work that
already shipped:

**`tools.files.recordsChanges` is `false` by default.**
`ToolCatalog.swift:167` passes it into `withFiles(…)`, so the
`FileChangeSet` that fills the `tool_call_update` locations is off unless
a `config.yaml` turns it on. If an editor is meant to see file locations
out of the box, that default is wrong. This plan does not change it; it
records the question.

## 8. Package changes

**This package:**

- `Examples/acp-agent/` moves to `Sources/acp-agent/`. It stops being an
  example, because it becomes the product.
- The `acp-agent` target adds a dependency on
  `FoundationModelsACPClient`, on `ArgumentParser`, and on `Noora`.
  There is no cycle: the client package depends on the wire and Extras
  only.
- `Package.swift` declares `github.com/tuist/Noora`, pinned to an exact
  version. See §5.2.
- `Package.swift` declares `apple/swift-argument-parser` from 1.8.0. The
  version floor matches Extras, and the package is already resolved.
- `Examples/acp-print/` does not move, and it does not change.
- The `acp-agent` executable product keeps its name, so `swift run
  acp-agent` and the tier-3 spawn still name one binary.

**Upstream, and blocking §5.7:**

- `FoundationModelsRouter` makes `ResolutionProgress.fraction` and
  `ResolutionProgress.slots` public.

**Upstream, and blocking nothing — but worth doing:**

- `FoundationModelsRouter` uses MTP speculative decoding. See §7.1 for
  the three steps and the exact `mlx-swift-lm` entry points. Until this
  lands, an MTP model in a slot costs a download and returns no speed.

**Upstream, and blocking §5.12:**

- `FoundationModelsExtras` adds the `Doctorable` module. See
  `doctor-plan.md`, milestones D1 to D3.

**The client package:**

- A new `acp-client` executable target and product.

## 9. Testing

| Tier | Test | Gate |
|---|---|---|
| Unit | The subcommand tree, and each subcommand of §5.3. | none |
| Unit | `acp-agent run doctor` sends the prompt "doctor", and runs no check. | none |
| Unit | The prompt-source table of §5.5, each row. | none |
| Unit | The stop reasons and the doctor statuses map to the exit codes of §5.8. | none |
| Unit | A usage error goes to stderr, and exits 2. stdout stays empty. | none |
| Unit | `--cwd` with `--resume` is a usage error. | none |
| Unit | `config init` refuses to overwrite without `--force`. | none |
| Unit | `config init` writes a file that `ConfigurationLoader` reads back to the same values. | none |
| Unit | `config show --source` names the layer that set each key, in a two-layer fixture. | none |
| Unit | Each `Doctorable` conformance, against a fixture that fails and one that passes. | none |
| Integration | `--cwd` selects the project layer: two directories with different `config.yaml` files give different resolved configurations. | none |
| Integration | The `acp` subcommand takes the project layer from `session/new(cwd)`, and not from the process working directory. | none |
| Integration | `run` and `acp` give the same answer for one prompt, with a scripted model. | none |
| Integration | stdout is byte-identical to the concatenated chunks. Nothing is added. | none |
| Integration | With stderr a pipe, a default run writes nothing to it. `--verbose` writes the events, and `--quiet` writes nothing in a terminal. | none |
| Integration | A scripted `ResolutionProgress` drives the bar, and the bar never touches stdout. | none |
| Tier 3 | `acp-print` spawns `acp-agent acp`. Unchanged. | `ACP_TIER3=1` |
| Tier 3 | `acp-client` drives `acp-agent acp`. stdout is only the answer. No process outlives the run. | `ACP_TIER3=1` |
| Tier 3 | `acp-agent --out-of-process` starts its own `acp` mode and gives the same answer. | `ACP_TIER3=1` |
| Tier 3 | An interrupt of `--out-of-process` gives exit 4, and leaves no agent process. | `ACP_TIER3=1` |
| Tier 4 | `doctor` on a clean machine reports the models as not downloaded, and gives the size. | `ACP_TIER4=1` |

## 10. Milestones

| ID | Work |
|---|---|
| C1 | **Adopt Noora.** Declare it, and write `TerminalRenderer`: a spinner, a bar and a table, on stderr only. See §5.2. |
| C2 | The `ArgumentParser` dependency, the subcommand tree, and the usage text. Unit tests. |
| C3 | The `acp` subcommand. Move the present server code into it. |
| C4 | The `run` subcommand, in process, over `InMemoryTransport.pair()`. |
| C5 | The prompt source, stdout, the exit codes: §5.5, §5.6, §5.8. |
| C6 | The new defaults of §7. |
| C7 | The download progress of §5.7. Blocked by the Router change in §8. |
| C8 | The `config` subcommands of §5.11. |
| C9 | The `doctor` subcommand of §5.12. Blocked by Extras D1 to D3. |
| C10 | The interrupt of §5.9. |
| C11 | `acp-client` in the client package (its N1 to N6). |
| C12 | `--out-of-process`, and the tier-3 tests of §9. |

C1 runs first, because C7, C8 and C9 all draw through
`TerminalRenderer`. C2 to C6 are in order. C7 and C9 wait on the two
upstream changes of §8, so start those early. C11 is in another
repository, so it can run beside everything.

## 11. Open items

### 11.1 Measure the cold model load

We do not know what one model load costs, once the weights are on disk.
The number decides §11.3. The task: time `acp-agent run "hello"` from a
cold start, and from a warm page cache, with the configured profile. If
the cost is small, one binary is correct, and no daemon is necessary. If
the cost is large, a daemon pays for itself on the second run.

The new 27B default makes this more likely to matter, not less.

### 11.2 The interactive loop

Out of scope. The CLI is headless. An interactive loop needs terminal
input, line editing, and interrupt handling, and it is its own milestone.

### 11.3 The shared server (`serve`)

Only if §11.1 shows a cost. The shape:

- A unix domain socket, and not HTTP. The frames stay ndJSON, so the
  codec does not change. File permissions give the access control. HTTP
  would add a network, authentication and a push channel, and it would
  give nothing more to a local daemon.
- The wire package needs a socket transport. `StdioTransport` fixes its
  descriptors at `init()`, but `ByteReader` already reads any
  descriptor, so the work is small and it is upstream.
- The agent must accept more than one connection, and it must hold the
  session store above the connection. The session model is already
  correct, because `session/list` and `session/load` give sessions their
  own identity.

### 11.4 Two questions this plan records but does not answer

- **The `standard` model id.** `mlx-community/Qwen3.8-27B-4bit` is not on
  the development machine, and it was not verified against Hugging Face.
  The `doctor` model check of §5.12 exists partly for this.
- **`tools.files.recordsChanges` defaults to `false`.** See §7. Should an
  editor see file-change locations without a `config.yaml`?

## 12. Where this plan differs from `plan.md`

These are not edits. `plan.md` keeps its text. This list tells a reader
which document governs each item.

| Item | `plan.md` says | This plan says |
|---|---|---|
| The default models | §2.2: a profile for a 16 GB machine, on Qwen2.5. | §7: Qwen3 models, and a 32 GB floor. |
| The flag surface of `acp-agent` | §20.2: no flags, no config wizardry. | §5.4 gives it a small flag surface, because it is now the product. |
| The place of `acp-agent` | §20.2: an example, under `Examples/`. | §8 moves it to `Sources/`. |
| The flag surface of `acp-print` | §20.2: no flags. | The same. It does not change. |
| The name of the production CLI | §17: the CLI and the agent are one binary, in the shape `<cli> acp`. | §2 names it `acp-agent`, and §5.3 keeps that exact shape. |
| `<cli> instructions --eject` | §3.1 | §5.3 spells it `instructions eject`, to match the other subcommand groups. |
| The frontends | §19: the Mac app and the CLI consume the composition. | §4 adds one rule: the CLI consumes it through an ACP connection, and never directly. |
