---
comments:
- actor: claude-code
  id: 01kyjcvx89p66dj3xnbqn0x521
  text: |-
    **2026-07-26 — `additionalDirectories` is now supported**, which pins down what `ToolContext` must carry.

    `ToolContext` needs the session's **root set**, not just its working directory: `cwd` (privileged — the relative-path base) plus the ordered `additionalDirectories`. `files:` constructs its `PathGuard` from that set (upstream FileTool `939nnzx`, in progress).

    `shell:` needs nothing from this — `ShellContext` carries no workspace root and `check(workingDirectory:)` validates only `..` traversal and existence, so shell confinement is command/environment pattern rules rather than a filesystem boundary. Do not invent a root parameter for it here.

    Note the roots are **replaced on every `session/resume`**, not accumulated, so the tool set is rebuilt per resume rather than mutated in place — which fits the existing per-cwd construction model (project layer differs per cwd → per-session tool sets through `makeSession(tools:)`) with no structural change.

    Separately, `shell:`'s policy grew upstream since this task was written: `ShellPolicy` now returns `ShellPolicyOutcome` (`.allow` / `.ask(String)` / `.deny(String)`) with `remember(...)` and a `ShellDecisionStore`. The `shell:` config section decodes into a policy that can now ask, so the catalog should not assume a binary allow/deny.
  timestamp: 2026-07-27T18:19:48.873626+00:00
- actor: claude-code
  id: 01kymg5p4wzbnsk35ats7ervsb
  text: |-
    **2026-07-28 — `FoundationModelsSkills` is added as a fourth day-one package, but it is not a tool.**

    `Package.swift` now declares four siblings. Three contribute tools (`files`, `shell`, `mcp`); Skills contributes a **`SlashCommandProviding` conformer** instead. This task's catalog already anticipates exactly this — "an entry may pair its tool with a `SlashCommandProviding` conformer and the catalog feeds it into the session's command registry" — and the `skills:` entry is the first to use *only* that half.

    So `builtin(context:)` returns three tools, and the catalog separately yields one command provider. Keep those return paths distinct rather than pretending Skills is a tool that produces nothing.

    **Config section `skills:`** follows the same absence-enables rule as the others: omitted means skills discovery is on with defaults, `skills: false` disables it (no discovery, no `/id` commands).

    ## Readiness — the honest part

    Skills is **plan-only**: 808 lines of plan, no sources, no board. Unlike `files` and `shell`, which are built and tested, this entry is a commitment to build a package. Its two halves have very different dependency chains, and only one is day-one feasible:

    | Half | Needs | Depends on |
    |
- actor: claude-code
  id: 01kymh8jdmtr9dtxp31kcas560
  text: |-
    **Correction 2026-07-28 — my earlier comment mischaracterized Skills. It IS a tool.**

    I wrote that Skills is "not a tool" and contributes only a command provider. That is wrong about the package. Skills' own plan §7 states: *"The model-facing surface is **one fused `OperationTool`**"* exposing `search skill` / `list skill` / `use skill`, and its §6 describes **two listing surfaces** — the model's searchable catalog and the user's `/` menu — both first-class. I turned a sequencing constraint into an identity claim.

    So the catalog entry for `skills:` eventually registers **both** halves: an `OperationTool` and a `SlashCommandProviding` conformer. Build the entry so it can carry both, rather than assuming it will only ever yield a provider.

    What remains true is the readiness split, which is about shipping order only:

    | Half | Needs | Depends on |
    |---|---|---|
    | `/id` commands | Skills M1–M3 + M5 | Extras — shipped |
    | `search`/`list`/`use` tool | Skills M4 | `FoundationModelsOperations` 2/4/5 + `MetadataRegistry` M1–M4 — neither built |

    **The consequence is bigger than "the tool is late," and it should be visible when scoping day one: until the tool half lands, the model cannot discover or invoke a skill at all.** Skills are reachable only by a user typing `/id`. That makes day-one skills a user-facing convenience rather than an agent capability — a real difference from `files` and `shell`, which are model capabilities from the first turn. If "Skills as a built-in alongside Shell and File" is meant to give the *model* a new capability, that arrives with M4, not day one.

    Also softening one claim from the `045qr29` comment: Extras `c2pad49` is **wanted, not blocking**. Skills' §6 documents the workaround — "a host that wants full render fidelity calls `registry.call(id:arguments:)` directly" — and we are that host, since this package owns the command registry. We can special-case skills internally with no Extras change; the cost is that Skills stops being an ordinary provider and the cross-package vocabulary erodes. Prefer `c2pad49`; ship the workaround if it is slow.
  timestamp: 2026-07-28T14:15:06.932518+00:00
title: Untitled
---
|---|---|
    | `/id` slash commands (this entry, day one) | Skills M1–M3 + M5 | **Extras only** — already shipped (`DotfolderStack`, `TemplateEngine`, `FrontmatterDocument`) |
    | `search`/`list`/`use` tool (follow-up) | Skills M4 | `FoundationModelsOperations` 2/4/5 **and** `FoundationModelsMetadataRegistry` M1–M4 — neither built |

    Do **not** treat "skills as a built-in" as one indivisible item; the tool half would stall this task on two packages that have not started. The catalog seam for the model-facing tool can be left unfilled without blocking anything.

    Also blocking the command half: Extras `c2pad49` (a `SlashCommand.Body` case for provider-rendered prompts) — see `045qr29` for why neither existing case fits.
  timestamp: 2026-07-28T13:56:03.868985+00:00
depends_on:
- 01KY7EDAAEV7M16J19CESQ54ZR
position_column: todo
position_ordinal: '8380'
title: 'ToolCatalog: well-known sections construct the built-in roster'
---
Plan §7 (§7.1 + §7.3) + head decision. The marked ADD-TOOLS-HERE location. **Three sibling packages are built in day one — all three are declared `Package.swift` dependencies and all three appear in `ToolCatalog.builtin(context:)`:**

- `files:` → **FoundationModelsFileTool** (confined to the session cwd via PathGuard, plus any ACP `additionalDirectories`).
- `shell:` → **FoundationModelsShelltool** (ShellPolicy from the same stack layers).
- `mcp:` → **FoundationModelsMCP** (`MCPToolProvider`). The third built-in entry, not a follow-up. It is the dynamic one: the tools it yields depend on what each server advertises, and because `sessionTools()` is async while Router's tool-instancing pipeline is synchronous, connection MUST complete before the array reaches `makeSession(tools:)`. This task owns the catalog seam and the config-derived (`mcp:`) source; the ACP-supplied per-session `mcpServers` source, the transports, and the ToolCallUpdate reporting are task seve4r0.

Rationale for treating the trio as non-optional: ACP v2 deleted `fs/read_text_file`, `fs/write_text_file`, and all five `terminal/*` client methods and redirected agents to their own file access and their own execution via MCP (plan §8.6). So files + shell + mcp are the agent's *entire* reach into the user's world — file access, execution, extensibility — and the roster is incomplete without any one of them.

**Absence enables (REVERSED 2026-07-28 from "presence enables").** Every built-in is constructed unless the config turns it off: no `tools:` section at all, or a `tools:` section that doesn't mention a tool, means that tool is on with its own defaults. A section is written only to *configure* (body decodes as that tool package's own option type) or to *disable* (`name: false`). The old rule meant a user with no config file got an agent with no tools — the opposite of the works-out-of-the-box promise. Accept `true` as a synonym for `{}` so `shell: true` is not a confusing error. `false` sits OUTSIDE the body deliberately: the body is the tool package's own option type and unknown keys inside a known section are errors, so an `enabled:` key would force every tool package to carry a flag only this layer cares about. The codec therefore checks for a scalar first, then decodes the mapping. Disabling is per-tool, one at a time — no `tools: false` mass-switch and no `only:` allowlist. Note the consequence: a NEW roster entry arrives enabled for every existing user on upgrade, so adding one is a user-visible capability change to be released as such. **`mcp:` needs its own handling** — its body is a list of servers, not options: omitted means enabled-with-no-local-servers (client-supplied ACP `mcpServers` still connect), `[]` means the same, and `mcp: false` means MCP off entirely INCLUDING refusal of client-supplied servers (log the refusal, never drop silently). Per-cwd construction (project layer differs per cwd → per-session tool sets through makeSession(tools:)). Reserved future names: codeContext:, multitool:, skills:, agents:. Cross-repo: Router's tools-through-makeSession (jkdae4b) to run real turns; catalog + construction unit-testable before that.