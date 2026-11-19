# Architecture

## No backward compatibility

This package has not shipped, and none of the swissarmyhammer packages has. We do not keep backward compatibility, and we do not write code for it.

- When a file format or an on-disk layout changes, write and read only the new one. Do not keep a reader for the old format, and do not write migration code. Data on disk in the old format may simply stop working.
- When an API changes, change every caller in the same change, or in the packages that depend on it. Do not keep deprecated aliases, shims, or old overloads.
- Do not keep a schema version only so that an old file can still be read.

This rule holds until we ship. When we ship, this section will say what we promise from then on.

## Sub-agent sessions

A sub-agent is an ACP child session. One code path serves all sessions: a child is an ordinary
session with a parent link and a set of permitted methods. No component is special for a child.
The README section "Sub-agent sessions" says what a client sees. This section says where the code
lives. All of it is in `Sources/FoundationModelsACPAgent/Agent/`.

- **The table and the tree.** `RoutedACPAgent` holds one table of sessions (`ActiveSession`).
  `SessionTree` holds the parent links, and refuses a second parent and a cycle.
  `SessionCapabilitySet` is the set of permitted methods of a session. A root permits every
  method. A child permits what its `subagent_update` advertises (`cancel` only).
  `requirePermitted(_:on:)` is the one check that the handlers use.
- **The announcement.** `SubagentAnnouncer` observes each agent run, and queues its
  `subagent_update` before any message that uses the id of the child. `SubagentAnnouncement`
  builds the update. `SessionAnnouncementGate` holds the events of a session until its
  announcement went out. The projector of the child session (`SessionProjector`) is the same type
  as the projector of a root.
- **The link to the call.** `RunCallJoinTable` joins an `agents` call to the id of its run, so the
  final `tool_call_update` and the announcement name the same call. It also holds the holds on
  the final status of the `agents` calls (`AgentCallHolds`).
- **The messages.** `SubagentMessageProjector` makes the two `session_message` views of a message
  between a caller and a child. All sessions of one surface share it. It also reads the
  `messageDelivered` events of the session directory (`DirectoryMessageFeed`,
  `DirectoryMessageSource`), and gives the target of a directory message one incoming view with
  `SAH.SessionMessage` in `_meta` when the target takes the mail (ACPA-6).
- **The shutdown.** `SessionShutdownPause` pauses the open tool calls of a session and of the
  sessions nested in it. `SessionLifecycle` runs the order: suspend, pause, stop the runs, close.
  A user `session/close` cancels the runs, and a shutdown only stops them.
- **The cold resume.** `SessionResume` is the entry. `SessionResumeNested` restores the
  interrupted children through the runner of FoundationModelsAgents. `SessionResumeOpenCalls`
  rebuilds the join of the open `agents` calls. `SessionResumeBackgroundCalls` ends or joins
  again each open call whose run was in the background, from the journal of the session.
  `SessionResumeReplay` replays the tree before the
  response. `SessionResumeChildSync` sends the current snapshots of the children after the
  response. `SessionResumeRedrive` starts the restored runs after the snapshots.
- **The hot resume.** `SessionResumeHot` lets a new connection take a live tree, with no
  teardown. `SessionResumeHold` keeps the live updates and the new questions of the tree from the
  take until after the response and the snapshots of the children, in one queue for the whole
  tree. `ElicitationRelay` reads the hold of its tree when a question starts.

The dependency direction is one way. The agent depends on the Agents package for the runs, on the
Router for the sessions, and on the ACP wire package for the types, the trace validator and the
Markdown renderer (`ACPMarkdown`). None of these packages depends on the agent.

Tests prove this in process. The suites (for example `SubagentCancelTests`,
`SubagentSessionsReplayTests`, `ChildSessionProjectionTests`, `RedriveInterruptedRunsTests` and
`HotResumeTests`) use the scripted model, and they run the agent in the test process. A test spawns
a child process only when the subject is a process: a signal, an exit code, the stdio framing of
the shipped binary, the arguments of the command line, or the shell tool.

## Forks

A fork (D205) is a root ACP session with a copy of the history of its source up to a cut. The
Router maps the cut, and the agent builds the fork with its own surface and serves it as each
other root session. All of it is in `Sources/FoundationModelsACPAgent/Agent/`.

- **The handler.** `SessionFork` serves `session/fork`: the checks, the map of the cut in
  `_meta.sah.forkCut` to a turn (`SessionForkPoint`), the call of
  `RouterSessionDirectory.fork(_:)`, and the refusals. The fork gets the MCP servers and the
  additional directories of the request only; an omitted list gives none, as ACP states. The
  handler keeps that surface and the copied history in the agent for the launcher, by a new id
  of the request (`ForkLaunchID`). It sets that id as a task local around the fork call. The
  Router calls the launcher in the task of that caller, so the launcher reads the id of the
  request that it builds. A fork of the `sessions` tool or of the `sessions` endpoint runs in
  another task and has no id. Before the fork call the handler records the folder of the fork in
  the project store, so a failed save makes no fork. When the handler cannot open the fork that
  the directory made, it closes the fork before it gives the error, so no live fork stays.
- **The launcher.** The directory calls `AgentSessionLauncher.forkSession(_:)` after it mapped
  the cut, and before it registers the fork and mails its first prompt. `SessionForkLaunch`
  builds the fork there: it records the agent of the source for the fork, composes the surface
  (the surface of the `session/fork` request, else the MCP servers, the directories and the user
  presence of the source for a fork of the `fork session` operation of the `sessions` tool or of
  the `sessions` endpoint), calls `SessionLaunchForkRequest.makeFork(tools:additionalDirectories:)`
  one time with the tools and the additional directories of that surface, writes the history
  file of the fork (also an empty one), and puts the fork in the session table. The Router
  writes the directories to the `index.md` record of the fork, so the record holds them from the
  build and after a restart. So the first prompt runs on the surface of the agent, and a
  `session/resume` of the fork takes the live fork: nothing stops and restores it.
- **The turns.** The projector of each session records each delivered mail and the end of each
  answer in the retained history (`MailDeliveryRecord`, history only: no client gets them, and
  a replay leaves them out). `SessionForkHistory` counts the turns from these records with the
  rule of the Router: one turn for each delivered mail of a user message or of a message of
  another session, in the order of delivery. It rounds a cut to the edge of a batch, never cuts
  past the start of the answer that runs, and cuts the retained history at the same turn: a user
  message moves to its delivery in the copy. For a fork of the `fork session` operation it finds
  the cut from the tool calls of the fork transcript; when they do not tell the cut, the fork
  copies no entry, never the whole source. The projector of the source records the call that
  forked in its own step, so the launcher first waits, with a time limit, until the retained
  history holds a call of that round: the tool calls of the settled source transcript that the
  fork transcript does not keep. When the time limit ends, the launcher throws, and the
  directory refuses the fork. A history file of an earlier build gets the records
  that that build counted when it is read.
- **The restore.** A fork restores only by its own id (`restoreColdRoot`, and
  `AgentSessionLauncher.restoreSession(id:)` for the directory). The restore of a source restores
  no fork, and a run of a fork is claimed only by the restore of the fork. A model slot switch
  of a source moves each fork that the agent holds with a switch of its own, by its id
  (`ModelSlotSwitch`): the restore of the source moves only the recorded forks that have no live
  session.

The compile-time dependency direction does not change: the agent calls the session directory of
the Router, and the Router calls the agent for a fork only through the `SessionLauncher` port
that the Router declares.

## Transcript search

The transcript search (D207) finds the sessions and the turns that hold a text. All of it is in
`Sources/FoundationModelsACPAgent/Search/`.

- **The items.** `TranscriptSearchItem` is one item of the catalog: a chunk of the transcript of
  a session (`SessionSearchChunker` of FoundationModelsACP makes the chunks from the retained
  history, `SessionMergeEngine+SearchChunks`), or the session itself, with its facts
  (`TranscriptSessionMetadata`: the name, the slug, the tags, the folder, the agent, the recap
  and the last summary).
- **The index.** `TranscriptSearchIndex` is a public actor over one `MetadataSearcher` of
  FoundationModelsMetadataRegistry. The registry is the engine: its BM25, trigram and cosine
  signals decide the matches. The index has no store, no ranking and no embedding of its own.
  The searcher keeps its catalog and its vectors in the folder of the index with the persistence
  option of the registry (`CatalogPersistence`, with the model id of the `embedding` slot), and
  the index keeps no other file. The init only keeps its arguments. The host calls `load()`
  one time after the init: the load makes the searcher, reads the stored items with no embed
  (`MetadataSearcher.items()`) and makes the list of sessions from them. Each other method waits
  for the load, and starts it when no call started it. `RoutedACPAgent.init` loads the index of
  the agent, and the Mac app loads the index of its client folder. A stored catalog of an
  old format, of another model or that is damaged is dropped (`.storedCatalogDropped`), and the
  next changes build it again. Each change gives the searcher only the items that changed
  (`update(upserting:removing:)`). The diagnostics of the registry are logged with
  `ACPAgentTelemetry`. The agent holds one index over `AgentHome.serverSessionSearchDirectory`
  (`RoutedACPAgent.transcriptSearchIndex`). The Mac app makes a second index over
  `AgentHome.clientSessionSearchDirectory`. Only one index may use a folder at a time. The
  shutdown of the agent waits until the updates applied each change and the index saved it.
- **The updates.** `TranscriptSearchUpdates` keeps the index of the agent current. The agent
  gives each change with no wait, and one task applies the changes in their order
  (`TranscriptSearchApplier`), so a turn never waits for the index and a later change never
  comes before an earlier one. A failure is logged, and the next change goes on.
  - After each write of a history file (`writeHistory(of:)` at the end of a prompt, of a mail
    turn and of `session/close`, and the copy of a fork in `SessionForkLaunch`), the history goes
    to the index: its chunk items and its session item, with the summary of the session
    directory.
  - The updates read the events of the session directory. `factsChanged` (a rename, the tags,
    the recap) gives the new session item only. `archived` and `unarchived` give the session item
    that the directory reads. `started` of a session with a history in the session table gives
    its history: the directory registers a fork after the write of its copy, so the fork is
    indexed as its own session with its live facts.
  - `session/delete` removes the items of the session, and of each session recorded inside its
    folder (a fork records in the folder of its source).
- **The reconcile.** At launch, a task with a low priority reads the working folders of the
  project store. The host gives the rule "this folder is readable now" as a closure
  (`readableFolder` of `RoutedACPAgent.init` and `ComposedAgent.compose`; the default reads each
  folder). The reconcile reads nothing in a folder that the rule refuses, and the items of its
  sessions stay. For each other folder it reads the recording root from the settings of the
  folder, the record (`index.md`) and the `session-history.json` of each session folder, and gives
  the items of each session in one change. The index starts from its stored catalog, so the
  reconcile gives the searcher only the changed items. It removes the items of each session of
  the folder that has no history file, also a session that was deleted while the agent was off. It reads no summary of the session directory, because that read
  reads the recording root of each project. The facts of the session item come from the Router
  function that turns a record into a summary (`SessionSummary.init(record:)`), so the name and
  the slug follow the one rule of the Router. There is no rebuild command and no setting (D187).
- **The search and its session ids.** A session id of the index can be any string (the ACP
  `SessionId`), because the client index of the Mac app holds the sessions of other ACP agents,
  whose ids are UUIDs or other strings. `TranscriptSearchIndex.search(_:visibleSessions:)` with a
  `TranscriptIndexSearchRequest` gives a `TranscriptIndexSearchPage` of
  `TranscriptIndexSearchResult` values, each with its `SessionId`. The search of Multitool
  (`SessionSearchRequest`, `SessionSearchPage`) uses ULIDs: its overload searches only the
  visible sessions whose ids are ULIDs, and gives the ULID of each session. The agent
  (`AgentTranscriptSearcher`) uses that overload.
- **The changes for Spotlight (D207 (i)).** `TranscriptSearchIndex.changes()` gives each
  subscriber its own `AsyncStream` of `TranscriptSearchChange`, after the index applied the
  change: `.indexed` with each turn (`TranscriptSearchTurn`: the session, the turn index, the
  date and the text of each chunk with its kind) of a session whose chunks changed, and
  `.removed` for a session that it removed. The index emits in `index(_:removing:)`, so a turn,
  a fork, a delete and the reconcile each give their changes. A new session item (a rename, an
  archive) gives no change. `turns(of:)` and `allTurns()` give the same turns from the items.
  Each stream keeps the newest 1,024 changes that its subscriber did not read
  (`TranscriptSearchChangeFeed`, a `SubscriberFeed`), so a slow subscriber never stops the index. This package does
  not import Core Spotlight: the app writes the items and selects the kinds (Q71).
- **The host reads the server changes (^twh8ceh).** The index of the agent stays internal.
  `RoutedACPAgent.transcriptSearchChanges` and `ComposedAgent.transcriptSearchChanges` give a
  `TranscriptSearchChanges`: a public struct over that index with `changes()`, `turns(of:)` and
  `allTurns()` only. The struct holds the index privately, so the host cannot cast it back to the
  index, and cannot call `index`, `update`, `remove` or `load`. The Mac app reads this value for
  the Spotlight items of the sessions of the server, and reads its own client index directly.

The dependency direction is one way: the agent gives changes to the updates, the updates change
the index, and the index calls the registry. The index does not depend on the agent, so the Mac
app can use it alone.

## The share of a session

A share (D208) is a snapshot of a session that the host keeps. The agent makes the snapshot, and
the host saves it and gives the link. This package does not know where the host keeps a share.

- **The snapshot.** `RoutedACPAgent.snapshot(of:options:)` builds a `SessionSnapshot` of
  `ACPMarkdown` from the transcript updates of the Markdown export (`SessionTranscriptExport`).
  The export and the snapshot use one read of the retained history, and a session with no
  history gives the same `noHistory` error. `RoutedACPAgent` and `AgentTranscriptExporter`
  conform to the public `SessionSnapshotSource`.
- **The sharer.** The host gives its share calls as a `SessionShareHost` to the initializer of
  `RoutedACPAgent` (or to `ComposedAgent.compose`). The agent gives each `sessions` tool a
  `HostSessionSharer` over them, through `CatalogContext.sessionSharer`. Its source is an
  `AgentTranscriptExporter`, which holds the agent weakly, so the sharer makes no cycle.
- **The turn ends (Keep Updated).** `RoutedACPAgent.turnEnds()` gives each subscriber the id
  of the session at each prompt end and at each end of a turn that a mail started, after the
  write of the history (`SessionTurnEnds`). The host updates a share with Keep Updated on; the
  agent does not. The stream and the transcript search changes use one feed type
  (`SubscriberFeed`).

## The import of a session of another agent

An import (D209) copies a session of Claude Code or Codex into a new session of this agent. The
scan is in `Sources/FoundationModelsACPAgent/Import/`. The readers of the session files are in
the `ACPImport` target of FoundationModelsACP, and the protocol is the `SessionImporter` of
Multitool.

- **The roots.** The host gives the folder of each source agent that it can read as
  `importRoots: [ImportSourceAgent: URL]` to the initializer of `RoutedACPAgent` (or to
  `ComposedAgent.compose`). The `acp-agent` CLI gives `~/.claude` (or `CLAUDE_CONFIG_DIR`) and
  `~/.codex`. A source with no root is in the `unreadableSources` of each page.
- **The scan.** `AgentSessionImporter` (an actor) lists the session files of each root
  (`ImportSourceLayout`: `projects/*/*.jsonl` for Claude Code, `sessions/**/rollout-*.jsonl` and
  `archived_sessions/` for Codex) and reads their metadata with the `ACPImport` readers. It
  keeps the scan of each file by path, size and modification date (`ImportFileStamp`), so a
  second call reads only the changed files. The rows are the newest first, with the rows of the
  preferred folder first. The importer reads the roots only in a call: no child process, no
  watch, no write to a root.
- **The earlier imports.** `previousImports` of a row comes from the `importedFrom` of the
  sessions of the session directory, by agent and source id. It is information only (Q85).
- **The wiring.** The agent keeps one importer (`RoutedACPAgent.sessionImporter`) and gives it
  to the `sessions` tool of each session through `CatalogContext.sessionImporter`. The tool
  gives it to the `sessions` endpoint of the directory, beside the exporter, the searcher and
  the sharer.
- **The import.** `importSession` checks the agent (`SessionImportError.sourceUnreadable`) and
  the folder of the new session (`SessionImportError.folderUnavailable`). The write of the new
  session is the next step of D209: until it is in, the importer throws
  `SessionDirectoryError.importUnsupported` after the checks.

## Settings

The agent settings live in memory in one `SettingsStore` (in
`Sources/FoundationModelsACPAgent/Configuration/`). The store keeps one tree for each level: the
user level and the session level of each working directory. Each level has its own
`config.yaml`. The `settings` GraphQL endpoint and the `settings` tool (in
`Sources/FoundationModelsACPAgent/Settings/`) read and write the store through `SettingsEngine`.
The endpoint does not read the files. The store does.

- **A change of the store.** A `set` or a `clear` changes the tree of a level, checks the merged
  result, writes the file, and sends and logs a change with the key path. When the file of the
  level or the changed text does not parse, the store refuses the change. The message of that
  refusal is the message of the parser with no line of the parsed text, as for a load error,
  because a rendered line can hold a secret value.
- **An outside write.** The store watches each file that it read. When a file changes from
  outside, the store reads it again, and sends and logs a change with no key path.
- **A bad outside write.** When the new text does not read, render or parse, the level keeps its
  last good values. The store keeps a load error for the level (`SettingsLoadError`): the file
  path, the line, and a message. The `problems` query gives it. When the load error starts,
  changes or clears, the store sends and logs a change with no key path. The load error never
  holds the text of the file, because the file can hold a secret. A parse error gives the message
  of the parser with no line of the parsed text, and a render error or a read error gives a fixed
  message.

- **The recap policy (D206).** `RoutedACPAgent` gives the Router session directory a recap policy
  (`RouterSessionDirectory.useRecapPolicy(_:)`): a synchronous closure that calls
  `SettingsStore.isSessionRecapOnNow(for:)` for the working folder of a session. The store keeps a
  copy of the tree of each level that it holds under a lock, and changes it with each `set`,
  `clear`, reload and stop, so the closure reads the merged `sessions.recap` value from any thread
  with no hop to the store. A level that the store does not hold yet is read from its file. When
  the read fails, the closure logs a warning and gives `true`.

The dependency direction is one way: the endpoint depends on the engine, and the engine depends on
the store. The store does not depend on the endpoint. The Router does not depend on the store: it
calls the closure that the agent gave it.

## Profiles

A model profile is a file, `profiles/<name>.yaml`. `ProfileStore` (in
`Sources/FoundationModelsACPAgent/Configuration/`) sits beside `SettingsStore`, with the same
layers and folders: the project layer of a working directory, then the user layer, then the
profiles that ship in the resources of the library (`BundledProfiles`). The first layer that has a
name wins, as a whole file. `ProfileFile` decodes one file as Router's `ProfileDefinition`, with
each key that the file leaves out taken from the bundled `large`.

- **The selection.** `profile: <name>` in `config.yaml` selects a profile. `ConfigurationLoader`
  reads the file of the name for the working directory of the load, thus the resolved profile
  rides in the loaded configuration, and the agent resolves it with Router at its launch.
- **The default (D203).** When no layer sets `profile`, or the name is unknown, the load uses the
  largest bundled profile that fits: `BundledProfiles.fallbackName(using:)` reads the fit of each
  bundled profile from a `ProfileFitEstimating` source (the router), and gives `small` when no fit
  can be read. The read is async and a load is not, so the host makes the choice one time before
  the load and gives the name to the loader and to the `SettingsStore`. `ComposedAgent.compose`,
  `RoutedACPAgent` and the `config show` and `doctor` commands of the CLI call the same function.
- **The reads.** `ProfileLayers` reads the disk at each call, and needs no cache. The loader, the
  `models` engine, the doctor and the CLI read through it.
- **The writes.** `ProfileStore` saves and deletes the file of the user layer or of a project
  layer, after a decode checks it, and sends a change on its `changes()` stream. The `models`
  endpoint and `acp-agent profiles` write through it. A child agent run cannot save, delete or
  select a profile (D193, `ChildAgentRun`).

The dependency direction is one way: the `models` endpoint and the CLI depend on the store, and the
store depends on the settings folders. The store does not depend on an endpoint.
