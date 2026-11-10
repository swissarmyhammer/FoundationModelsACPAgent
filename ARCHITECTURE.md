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
  between a caller and a child. All sessions of one surface share it.
- **The shutdown.** `SessionShutdownPause` pauses the open tool calls of a session and of the
  sessions nested in it. `SessionLifecycle` runs the order: suspend, pause, stop the runs, close.
  A user `session/close` cancels the runs, and a shutdown only stops them.
- **The cold resume.** `SessionResume` is the entry. `SessionResumeNested` restores the
  interrupted children through the runner of FoundationModelsAgents. `SessionResumeOpenCalls`
  rebuilds the join of the open `agents` calls. `SessionResumeReplay` replays the tree before the
  response. `SessionResumeChildSync` sends the current snapshots of the children after the
  response. `SessionResumeRedrive` starts the restored runs after the snapshots.
- **The hot resume.** `SessionResumeHot` lets a new connection take a live tree, with no
  teardown. `SessionResumeHold` keeps the live updates of the tree from the take until after the
  response and the snapshots of the children, in one queue for the whole tree.

The dependency direction is one way. The agent depends on the Agents package for the runs, on the
Router for the sessions, and on the ACP wire package for the types and the trace validator. None
of these packages depends on the agent.

Tests prove this in process. The suites (for example `SubagentCancelTests`,
`SubagentSessionsReplayTests`, `ChildSessionProjectionTests`, `RedriveInterruptedRunsTests` and
`HotResumeTests`) use the scripted model, and they run the agent in the test process. A test spawns
a child process only when the subject is a process: a signal, an exit code, the stdio framing of
the shipped binary, the arguments of the command line, or the shell tool.
