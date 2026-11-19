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
Router makes it, and the agent serves it as each other root session. All of it is in
`Sources/FoundationModelsACPAgent/Agent/`.

- **The handler.** `SessionFork` serves `session/fork`: the checks, the map of the cut in
  `_meta.sah.forkCut` to a turn (`SessionForkPoint`), the call of
  `RouterSessionDirectory.fork(_:)`, and the refusals. The fork gets the MCP servers and the
  additional directories of the request only; an omitted list gives none, as ACP states. The
  handler writes the history file of each fork, also an empty one.
- **The turns.** `SessionHistory` counts the turns of the retained ACP history with the rule of
  the Router: each user message and each incoming `session_message`. `SessionForkHistory` cuts
  the retained history at the same turn, and finds the cut of a fork that the `fork session`
  operation of the `sessions` tool made.
- **The restore.** `SessionForkRestore` holds the steps of the cold restore for a fork: it stops
  the live fork of the directory, which runs the tools of the source, gives the fork the agent of
  its source, and gives a fork with no history file the history that it copied. Only a fork of
  the `fork session` operation has no history file. When the tool calls do not tell its cut, the
  fork copies no entry, never the whole source.

The dependency direction does not change: the agent calls the session directory of the Router,
and the Router does not call the agent for a fork.

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

The dependency direction is one way: the endpoint depends on the engine, and the engine depends on
the store. The store does not depend on the endpoint.

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
