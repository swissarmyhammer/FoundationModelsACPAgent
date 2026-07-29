---
comments:
- actor: claude-code
  id: 01kymatc02c2w0zan3zdywvq13
  text: |-
    **BLOCKED on Router `ke41yth` — and the blocker is bigger than the routerId segment.**

    Checked Router's source rather than assuming. `Router.recordingsDir` is a stored property set once at `init` (`Router.swift:67`, `:151`, `:164`), and `recordingDirectory(forSessionId:)` builds every session's path from it (`RoutedLLM.swift:260-266`):

    ```swift
    recordingsBase
        .appendingPathComponent(routerId.description, isDirectory: true)
        .appendingPathComponent(sessionId.description, isDirectory: true)
    ```

    So **one Router writes every session under one root.** That is fine for a home-rooted layout and fatal for a project-local one: a single agent process serves concurrent ACP sessions in *different repos*, and one resident profile means one Router holding one loaded model — a Router per project is not available, since keeping the model loaded once is the whole point.

    **Project-local transcripts are therefore not implementable until Router accepts a per-session recording root.** Filed as `ke41yth` on Router's board, covering both asks:

    1. **Per-session recording root** (blocking) — e.g. `makeSession(recordingRoot:)`, falling back to the Router-level `recordingsDir` when omitted so existing callers are untouched.
    2. **Omittable `routerId` segment** (wanted, not blocking) — with a per-session root the segment turns actively harmful, producing `<cwd>/.<name>/transcripts/<routerId>/<sessionId>/` and reintroducing the pile-of-ULID-directories problem this whole design is trying to avoid. Record the routerId as metadata inside the session directory instead: provenance, not structure.

    Note `makeSession` **already takes `workingDirectory:`**, so Router could derive the path itself — but that is the wrong split. This package owns the location *policy* (dotfolder name, project vs home vs absolute, the `.gitignore` placement); Router owns the *writing*. Handing Router a root keeps the boundary that `TranscriptStore` never records; handing Router a policy breaks it.

    **What can proceed now, before `ke41yth` lands:** the read side and the policy itself are unblocked — `sessions(inProject:)`, the `projects.jsonl` registry, title derivation, `updatedAt`, cursor pagination, `session/delete`, and the `.gitignore`-in-`transcripts/` rule are all this package's own code and need nothing from Router. Only the write path's root has to wait.
  timestamp: 2026-07-28T12:22:30.146390+00:00
- actor: claude-code
  id: 01kymf889mna41kkxp7rmqg0p5
  text: |-
    **Correction 2026-07-28 — transcripts are COMMITTED. The `.gitignore` requirement in this task's body is reversed.**

    The framing is that **the transcript is the source and the code is its output**: the prompts, decisions, and corrections that produced a change are the durable artifact, and the diff is what fell out of them. A repo keeping only the diff has kept the compiled result and discarded the source. So committing transcripts is the point, not a hazard.

    **Do not write a `.gitignore`.** Nothing under `.<name>/` is ignored by default. Replace that acceptance criterion and its test with the following.

    **Write `.gitattributes` instead**, in `transcripts/`:
    - `linguist-generated=true` on `transcripts/**` — keeps them out of language stats and collapses them by default in PR review, so a two-line code change does not arrive as a ten-thousand-line diff.
    - `sessions.jsonl merge=union` — see below.

    **Merge behavior is now a design obligation.** Per-session directories are what make this work: two developers produce two `sessionId` directories and two `transcript.jsonl` files, so they never touch the same bytes — no conflict by construction. The one shared file is `sessions.jsonl`, which *will* conflict. Keep it strictly **append-only with one self-contained record per line** so a union merge resolves it, and prefer treating it as a **derivable cache** (rebuildable by scanning session directories) so a mangled index is never load-bearing.

    **Secrets are the sharp edge, and this task carries part of the mitigation.** A committed transcript is a permanent, pushed record of everything the agent saw — a `.env` read by `files`, an API key echoed by `shell`, a token in a stack trace. Once committed it is in history forever, on every clone, public the moment the repo is, and *not* fixable by deleting it in a later commit. Two consequences here:
    - **Redaction is promoted from optional to load-bearing.** Router takes a `redact:` parameter at construction; this package must configure it **by default** rather than leaving it to the frontend. Default patterns should cover assignments to `*_TOKEN` / `*_KEY` / `*_SECRET` / `PASSWORD`, `Authorization` headers, PEM blocks, and `.env` contents. **Verify what Router's `redact:` actually covers today before assuming** — that answer sets how much has to be added here.
    - **`recording.level: metadata`** committed in the project layer is the escape hatch for repos that cannot risk content, applying to everyone in that repo rather than whoever remembered.

    **`session/delete` can no longer promise what it did.** It removes the working-tree directory and the index entry, but anything already committed stays in git history. Neither the ACP response nor the docs may imply otherwise — update that acceptance criterion accordingly.

    **Repo size is a real, unmitigated cost.** At `RecordingLevel.full` a transcript embeds the full contents of every file fed to a tool, and git keeps it forever; a few large refactor sessions can outweigh the source they produced. `recording.level` is the only control. Document it plainly rather than discovering it at 2 GB.
  timestamp: 2026-07-28T13:39:59.412468+00:00
- actor: claude-code
  id: 01kymfq91nh3tntv93a8kdvxr8
  text: |-
    **Correction 2026-07-28 — no redaction. Supersedes the redaction bullet in my previous comment.**

    Transcripts are recorded **verbatim**. Do not configure Router's `redact:`, and drop the "verify what `redact:` covers today" upstream question — it is not needed.

    The operating assumption, stated so it can be checked later: **this is a development tool, in development trees, against development credentials.** A key appearing in a dev session is a dev key, and the control for a repo whose history should not be public is the repo's own visibility — a real boundary enforced by the host, not a heuristic.

    Two affirmative reasons beyond the assumption, both of which make this the better design rather than merely an accepted risk:

    - **Redaction corrupts the source.** Once the transcript *is* the source, a redaction pass edits it, and a pattern matcher that rewrites a line it misidentifies produces a record that no longer says what happened. A source you cannot trust to be faithful is worse than one you have to keep private.
    - **Partial redaction invites misplaced confidence.** No pattern set catches every secret, so a "redacted" transcript is one someone eventually treats as safe to publish. Verbatim-and-private is an honest posture; scrubbed-and-maybe-safe is not.

    **`recording.level` stays the control** for repos that want less — `metadata` for shape without content, `off` for nothing — committed in the project layer so it applies to everyone working there. That is a per-repo decision about what is worth keeping, which is the right granularity; a per-string guess at write time is not.

    Everything else in the previous comment stands: no `.gitignore`, write `.gitattributes` (`linguist-generated=true`, `sessions.jsonl merge=union`), append-only one-record-per-line index treated as a derivable cache, and `session/delete` clearing the working tree but not git history.
  timestamp: 2026-07-28T13:48:11.701308+00:00
- actor: claude-code
  id: 01kymsxqxx0b7tvg7bv70m30rt
  text: |-
    **Spec audit — §4 Session List (2026-07-28). One correction to this task, plus two decisions the spec leaves open.**

    **Correction: `title` and `updatedAt` are OPTIONAL.** `SessionInfo` requires only **`sessionId` and `cwd`** — `title`, `updatedAt`, and `additionalDirectories` are all optional. My earlier comment called title generation an obligation ("four of its fields are obligations rather than passthroughs"); that overstated the spec. Generating a title is still the right product call — a client tab reading "Untitled" is worse than one reading "fix the resume cursor" — but it is **our choice, not conformance**, and it must not block this task shipping.

    **`cwd` and `additionalDirectories` are immutable once a session exists.** `SessionInfoUpdate` carries **only** `title` and `updatedAt` (each nullable to clear). No field exists for `cwd` or the root list. Two consequences:
    - Confirms the resume rule from the other side: a mismatched `cwd` must be **rejected**, since no mechanism exists by which a session's `cwd` could legitimately change.
    - **No way to push a root-list change.** `session/resume` may legitimately activate a different `additionalDirectories` set, but nothing can notify a connected client — it learns on its next `session/list`. Store and report the *most recent* activation; do not synthesize an update notification for it.

    **Decision 1 — ordering is unspecified by the spec, so it is ours, and the cursor must match it.** Sort **`updatedAt` descending, `sessionId` tiebreak**. The cursor must encode that same sort key, not an offset. An ordering chosen in the query with a cursor built on something else is the classic duplicate/skip bug — both halves have to agree.

    **Decision 2 — listability is undefined; here is the rule:**

    | State | Listed? | Why |
    |
- actor: claude-code
  id: 01kymt96nse3yng0x74z39dsxw
  text: |-
    **Spec audit — §5 Session Delete (2026-07-28). This REVERSES the hard-delete decision in my earlier comment. Implement delisting, not destruction.**

    My earlier comment specified a hard delete — remove `<cwd>/.<name>/transcripts/<sessionId>/` and the index entry — reasoning that "a soft delete leaves full prompts and file contents on disk." That was correct when written and stopped being correct once transcripts became **committed source**. Two things the audit turned up:

    **1. The protocol asks for far less than we were volunteering.** The schema is narrow and explicit: `DeleteSessionRequest` is *"Request parameters for deleting an existing session **from `session/list`**,"* and `SessionDeleteCapabilities` means *"the agent supports deleting sessions **from `session/list`**."* The only normative requirement is *"Deleted sessions no longer appear in future `session/list` results,"* and the page states outright that soft-vs-hard **is not mandated** — "only the user-facing behavior matters."

    **2. Destroying source on a list-removal gesture is disproportionate.** Under §5's own framing the transcript *is* the source. A client affordance that removes an item from a picker must not delete tracked files — and it would stage a git deletion the user then has to reckon with, i.e. the agent quietly editing a repo as a side effect of a UI click.

    The original privacy rationale no longer pays either: transcripts are committed, so a hard delete leaves the content in git history anyway. It buys nothing and costs the source.

    **Revised implementation:**
    - Write a **tombstone** in `sessions.jsonl` (append-only, already the listability index) and **leave `transcript.jsonl` untouched on disk**.
    - `session/list` stops returning it — precisely and entirely what the protocol requires.
    - Deleting content stays a deliberate act the user performs on their own repo with their own tools.

    **Two implementation-defined behaviors the spec hands us, both now decided:**
    - **Deleting an active session:** close first (`session/close` semantics — cancel work, emit `idle` with `stopReason: "cancelled"`, free resources), then delist.
    - **Resuming a deleted session: error.** The transcript is still on disk so resume could technically succeed, but a delete that a later resume silently undoes is not a delete. Recovery is un-tombstoning by hand, not a protocol call.

    Already-deleted and never-existent SHOULD succeed silently — **a tombstone is naturally idempotent**, a small point in its favor.

    **Supersede these acceptance criteria from the earlier comment:**
    - ~~Delete removes the transcript directory~~ → Delete writes a tombstone; `transcript.jsonl` still exists afterward.
    - Keep: session disappears from subsequent lists; second delete succeeds silently.
    - Add: resume of a deleted session errors; delete of an active session closes it first.
  timestamp: 2026-07-28T16:52:44.857655+00:00
- actor: claude-code
  id: 01kynjpja5hdccwb7yfv9pd0v3
  text: |-
    **UNBLOCKED 2026-07-28 — Router `ke41yth` has landed. Supersedes the "BLOCKED on Router" comment above.**

    Verified in Router's source, not just the board:

    ```swift
    func recordingDirectory(forSessionId sessionId: ULID, recordingRoot: URL? = nil) -> URL {
        if let recordingRoot {
            return recordingRoot.appendingPathComponent(sessionId.description, isDirectory: true)
        }
        return recordingsBase
            .appendingPathComponent(routerId.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)
    }
    ```

    Both halves of the ask are in one clean change:
    - **Per-session root** — `makeSession(recordingRoot:)` gives `<cwd>/.<name>/transcripts/<sessionId>/` directly, so one Router can write sessions in different repos.
    - **No routerId segment** on that path, which was the second half. Omitting the parameter reproduces the old `<base>/<routerId>/<sessionId>/` layout exactly, so existing callers are untouched.

    Router ships `PerSessionRecordingRootTests` covering the flat layout and a fork nesting under it with no routerId segment.

    The ownership boundary held as argued: Router took a **root**, not a policy. The dotfolder name, the project-vs-home-vs-absolute choice, and the `.gitattributes` placement all stayed here, and `TranscriptStore` still never records.

    **So the write path is unblocked and this task can be implemented end to end.** Nothing in it now waits on another repo. Read side (`sessions(inProject:)`, `projects.jsonl` registry, title derivation, `updatedAt`, cursor pagination, tombstone delete) was already unblocked; the write path was the only piece pending.

    Reminder of the corrections layered above, since they contradict parts of the original description: transcripts are **committed** (no `.gitignore`; write `.gitattributes` with `linguist-generated=true` and `sessions.jsonl merge=union`), **no redaction**, delete is a **tombstone** not a hard delete, and `title`/`updatedAt` are optional in `SessionInfo` rather than owed.
  timestamp: 2026-07-28T23:59:28.581156+00:00
- actor: claude-code
  id: 01kypy4vwj70r5gx810bhwx4h2
  text: |-
    **2026-07-29 — the ACP-session ↔ Router-session correspondence, and the two filters it implies.** New plan §5 subsection.

    **The ACP `sessionId` IS the root Router session's ULID** — the same identifier, serialized, not a mapping. ACP's `SessionId` is an opaque string and a ULID is one. A mapping table would be a thing that can drift, and the first symptom is a `session/resume` restoring the wrong conversation.

    **Router already distinguishes two kinds of descendant, and they are not the same thing:**

    | | What | Links via | Directory |
    |---|---|---|---|
    | **fork** (`fork(workingDirectory:)`) | a branch of the *same conversation* | `parentId` | nests: `<rootId>/<forkId>/` |
    | **agent spawn** (`AgentSpawn(parentSessionId:parentToolCallId:)`) | a *sub-agent launched by a tool call*, possibly in another tree | `parentToolCallId` | own directory; linkage is the id, not nesting |

    **Neither is an ACP session.** Forks and sub-agents never get an ACP `sessionId`, never appear in `session/list`, never accept `session/prompt`. From the client's side a sub-agent is something the agent *did* — a tool call — not a second conversation it can drive.

    ## Two rules this task must implement

    **1. `session/list` filters to roots.** A directory walk over project-local transcripts would otherwise surface nested fork directories and sibling sub-agent directories as if they were conversations. The predicate is exact: **listable iff `parentId == nil` and `agentSpawn == nil`.** Both facts are already on Router's sidecar, so this costs a predicate, not a schema change. This supersedes the earlier "has a persisted transcript is the listability test" — that rule stands for zero-turn sessions but is not sufficient on its own.

    **2. Sub-agent transcripts are siblings, not children.** Router's model says an agent spawn may sit "under an entirely different router or recording tree," which is right: a sub-agent given its own working directory belongs to *that* project's transcripts. So sub-agents land as siblings under whatever project root their cwd implies, linked by `parentToolCallId`; forks keep nesting under the parent as Router already does. Rule 1 is what keeps siblings out of the picker.

    ## Why it matters now, before Agents exists

    `FoundationModelsAgents` is plan-only, so none of this is exercised yet — but the transcript layout is being built by this task, and getting the correspondence right now is what avoids a layout migration later. The listability predicate in particular is cheap to add today and expensive to retrofit once directories exist in the wild.

    Also note `AgentSpawn.parentToolCallId` is documented as "the correlation id a transcript browser matches against that turn's recorded tool-call entry" — the **same** id as ACP's `toolCallId`, Router's `SessionEvent.toolCall(id:)`, the MCP call handle, and `OperationEvent.correlationID`. One key across five layers, which is what makes a sub-agent's transcript reachable from exactly the tool call the client watched.
  timestamp: 2026-07-29T12:38:45.906368+00:00
title: Untitled
---
|---|---|
    | active | yes | — |
    | closed | **yes** | close frees resources but retains the transcript; resuming is the point |
    | deleted | no | by definition |
    | created, zero turns | **no** | nothing worth resuming; noise in every picker |

    The zero-turn rule is free given the §5 layout: a session directory exists only when there is something to record, so **"has a persisted transcript" *is* the listability test** — no extra state to track.

    **`cwd` filter miss is not an error.** A filter naming a directory we have never seen returns an **empty `sessions` array**, not an error — a client opening a fresh project asks this constantly. Filtered list = one directory read (cheap, thanks to project-local storage); unfiltered = the `projects.jsonl` registry walk.

    Other spec points confirmed against the plan: cursors opaque (clients MUST NOT parse/modify/persist), missing `nextCursor` MUST be treated as end of results, agents SHOULD error on an invalid cursor, agents SHOULD enforce reasonable page sizes, and `ListSessionsResponse.required = ["sessions"]` so an empty page is `{"sessions": []}`.
  timestamp: 2026-07-28T16:46:29.309719+00:00
position_column: todo
position_ordinal: '8680'
title: 'Transcript location policy: project-local, keyed by ACP session'
---
Plan §5. **REWRITTEN 2026-07-28 — the location decision reversed from home-keyed-by-slug to project-local.**

## The new policy

`<cwd>/.<name>/transcripts/<sessionId>/` — inside the same project dotfolder that holds `config.yaml` (§4). The reframe that drove it: **a transcript is project context, not a personal activity log.** What the agent did to this repo belongs with this repo.

```
<cwd>/.<name>/
    config.yaml                  # committable — team settings
    transcripts/
        .gitignore               # `*` + `!.gitignore`
        sessions.jsonl           # this project's session index
        01K3G.../                # ACP sessionId
            transcript.jsonl
```

**Project slugs are deleted.** The `-Users-wballard-…` scheme existed only to name a project inside a shared home root. Storage is now inside the project, so the directory *is* the identity — nothing to encode, escape, or reverse for display. The slug survives *only* under `transcripts.location: home`, which is now the non-default escape hatch.

**The organizing key is the ACP session, not the Router run.** `sessionId` is stable across `session/resume`, is what `session/list` enumerates, and is what a user means by "that conversation."

## Blocking upstream question — raise on Router's board first

Router's layout is `<recordingsDir>/<routerId ULID>/…`, a fresh id per process run, which groups by *process lifetime* — an implementation detail nobody browses by. This task wants no routerId path segment; a routerId may correspond 1-1 with an agent run, but that is **provenance, not structure** — record it as metadata inside the session directory instead.

Dropping that segment is a change to **Router's** recording layout, which this package does not own (the standing rule below: `TranscriptStore` never records). **Do not build against a flat layout until Router can produce one.** Either Router gains a way to write without the routerId segment, or this package accepts one vestigial level and documents it. Everything else in this task holds either way.

## The cost, and its mitigations — do not skip these

At `RecordingLevel.full` a transcript holds complete prompts, the contents of every file fed to a tool, and full model output. Inside a repo that is reachable by `git add -f`, `zip -r`, any backup tool sweeping the working tree, and anyone the directory is shared with. This was the previous decision's strongest argument and reversing the decision does not retire it.

- **`.gitignore` goes in `transcripts/`, NOT the dotfolder root.** The old plan wrote `*` + `!.gitignore` into `.<name>/` wholesale — that is now **wrong**, because the same dotfolder holds `config.yaml`, `Instructions.md`, and `commands/`, which a team may want to commit. Scope the ignore to the `transcripts/` subdirectory. Write it at directory creation, **before the first transcript byte**.
- **`recording.level` in the project layer is the real control** for sensitive repos — committing `recording.level: metadata` gives every session in that repo a content-free floor, for everyone, by default. Stronger than any ignore rule because the bytes are never written. Document it as the answer.
- **Deleting the checkout now deletes the history.** Coherent under the new framing (same as `.git`), but state it plainly.

## Cross-project browsing needs an index

`allProjects()` was a walk under one home root; it is now a filesystem-wide hunt. Keep a registry in the **user** layer: `~/.config/<name>/projects.jsonl`, appended when a session is created in a previously unseen cwd — absolute path, first seen, last seen. **Paths only, never content**, so it re-introduces none of the leak surface. It is a cache, not a record: regenerable, safe to delete, and stale entries (repo deleted or moved) are skipped on read rather than pruned eagerly.

## ACP `session/list` gets simpler, not harder

It takes an optional `cwd` filter and an editor overwhelmingly wants "sessions for the project I have open" — now a single directory read instead of a filtered walk across every project ever touched. `SessionInfo` obligations are unchanged from the previous revision:

- **`title`** — derive from the first user prompt (truncated, single-line), persist in `sessions.jsonl`, emit `session_info_update` when it first appears.
- **`updatedAt`** — RFC 3339, maintained and read from the record, not stat-ed.
- **`additionalDirectories`** — the complete **ordered** list, persisted per session (not derivable from `cwd`, not recoverable later; a `Set` round-trip would drop information the spec obliges us to report). Replaced on every resume, not accumulated.
- **`cursor` / `nextCursor`** — cursor-paginated, opaque to clients, bounded page size, invalid cursor is an error. Cursor encodes a stable sort key (`updatedAt` desc + `sessionId` tiebreak), not an offset.

## `session/delete`

Advertise `capabilities.session.delete` and honor it with a **hard** delete: remove `<cwd>/.<name>/transcripts/<sessionId>/` and its `sessions.jsonl` entry. A soft delete leaves full prompts and file contents on disk, which is the opposite of what the user asked for. Close an active session first, then delete. Already-deleted or never-existent succeeds silently. The project-local layout makes this simpler than the old scheme — the directory is unambiguous and inside the project the client is already scoped to.

## Ownership boundary — unchanged

**`TranscriptStore` never records and never restores.** It owns the root location policy, the session directory scheme, the project registry, and lightweight browse summaries (read via Router's own readers). Writing events, reconstructing entries, applying compaction checkpoints, and rebuilding a live session are Router's; this package calls Router to do them. `sessions(inProject:)` is now a plain directory read; `transcript(for sessionID:)` goes through Router's `TranscriptTree`; restoration is `RoutedLLM.restoreSessionTree`.

## Tests

- [ ] A session in a cwd writes to `<cwd>/.<name>/transcripts/<sessionId>/` and nowhere else.
- [ ] `.gitignore` exists in `transcripts/` before any transcript content, and does **not** ignore `config.yaml` / `Instructions.md` / `commands/` in the dotfolder root.
- [ ] Two sessions in different cwds write to their own project directories; neither sees the other via `sessions(inProject:)`.
- [ ] Two concurrent sessions in the **same** cwd share the directory and both appear in that project's `sessions.jsonl`.
- [ ] `projects.jsonl` gains an entry for a new cwd, is not duplicated on a second session there, and a deleted-repo entry is skipped rather than erroring `allProjects()`.
- [ ] Title derived, persisted, and round-tripped; `updatedAt` advances; `additionalDirectories` order preserved.
- [ ] Paging covers every session exactly once; garbage cursor errors.
- [ ] Delete removes the directory and the index entry; second delete succeeds silently.
- [ ] `transcripts.location: home` still works and still uses the slug scheme; an absolute path wins outright.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.