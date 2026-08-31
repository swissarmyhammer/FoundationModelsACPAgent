---
assignees:
- claude-code
depends_on:
- 01KYSV8M8HV7R9W51QG63BBYR8
- 01KYSV7GHQ7049N8DW5NH9MYWS
- 01KYSVA1A4HXA6RYSJBE2XERFM
position_column: todo
position_ordinal: 8f80
title: 'session/resume: cwd equality, restore, replay as whole-message upserts'
---
## What
Plan.md §7.4 and §8.3. Work in `Sources/FoundationModelsACPAgent/Agent/SessionResume.swift`.

**Status as of 2026-08-31: the upstream restore API is APPROVED and being built.** The Router team's user chose to publish now, so this no longer waits for us to compile. Their card is `01M1CY02GKDW8CXY74NW30HZSY`. **Keep this task blocked until that lands**, then build against the real signature.

Why it was closed in the first place: restore was public when written, then demoted on 2026-08-26 by a pass that proved the public surface against four consumers. This package was not one of them, because a consumer that nobody builds cannot break a build.

## The API being published

```swift
let restored = try await profile.standard.restoreSession(
    id: sessionId,
    recordingRoot: transcriptRoot,
    instructions: freshInstructions,   // nil keeps the recorded instructions
    tools: try await ToolCatalog.sessionTools(context: context)
)
// restored.session             -> RoutedSession
// restored.configurationReport -> missingTools
// restored.contextMismatches
```

`SessionConfigurationRestorationReport`, `MissingTool` and `ContextMismatch` become public with `RestoredSession`. `restoreSessionTree` and `RestoredSessionTree` stay internal; we asked for no tree walk.

Why this shape:
- **One session by id, not a tree.** Our ACP `sessionId` IS the root Router session ULID (§4.2). We never address a fork or a spawn over the wire: §7.5 leaves `session/fork` unbuilt and §9 lists roots only.
- **We need the mismatch report.** Resume is where our roster legitimately differs from the recording: a project layer that now says `shell: false`, an MCP server that fails `waitUntilReady()` and takes all of its verbs with it, a replaced `additionalDirectories` set, or a deleted skill. `missingTools` is how we say that out loud instead of resuming into a quietly smaller roster. **Report it to the client. Do not swallow it.**
- **Name-based tool re-attachment is enough.** We build all per-session state and hand over the instances.
- **`instructions:` closes a live trap.** Without it, restore re-applies `node.sidecar.instructions` silently. Our fresh assembly would have gone nowhere and the session would have run on stale recorded instructions, with no error and no report.
- **A changed instructions string is journalled, not returned.** Router appends one `TranscriptEvent.Kind.divergence` event carrying a stable phrase and the two string lengths, with neither body and no hash. Identical or nil instructions journal nothing. The party who needs to know is whoever reads the committed transcript later, who did not pass the argument.

## Two upstream details to check when it lands

**The deleted-session error is NOT the obvious one.** A missing session raises **`TranscriptTreeError.sessionNotFound`**, not `SessionTreeRestorationError`. `SessionTreeRestorationError` covers restore-specific failures such as a non-root id. Catch the case that a missing session actually raises, and confirm it against the shipped code before relying on it. Do not match on a message string.

**The cwd pre-check is undecided upstream.** Our §7.4 refuses a resume whose `cwd` differs from the recorded creation cwd. There is no public way to read the recorded cwd without restoring: `SessionSidecar` publishes no stored property and `TranscriptEvent` does not carry cwd. Upstream will either add a read-only accessor, if it costs one property, or document restore-then-compare as the supported path. **Check which shipped.** If it is the accessor, check before restoring. If not, restore and then compare `restored.session.workingDirectory`, reject on a mismatch, and close the session you just built rather than leaking it.

**Do not reimplement restore against `transcript.jsonl`.** That forks Router's format and breaks silently on their next change.

**The phantom card.** Plan.md §7.4 formerly cited Router card `6j4bven`. No such card exists on their board. It is removed.

## The replay half can proceed now

It reads through `TranscriptStore`, built on the public `TranscriptEvent.merged(under:)`.

`session/resume(sessionId, cwd, mcpServers, additionalDirectories, replayFrom)`:

- `cwd` MUST equal the recorded original. A mismatch gives an error, never a silent re-root.
- Reassemble our side from the recorded cwd: the config layer, the instructions, the tools and the confinement. Reconnect the config and client MCP servers. The client list is authoritative on each reconnect and is never persisted.
- `additionalDirectories` is authoritative and replaceable. A non-empty list is the complete new root set. Omitted or empty means no additional roots. Never inherit former roots. Persist the new ordered list to the index.
- Replay: `replayFrom: {"type": "start"}` replays before the response returns. Omitted or null means no replay. Replay sends whole-message upserts (`user_message`, `agent_message`, `agent_thought`) with the original `messageId` values, never `*_chunk`, so a client that saw chunks converges through §8.3's replace row. Replay reads the full recorded history; fold checkpoints are not messages and are not sent. Write the replay path with `ReplayFrom` as an inclusive cursor parameter.
- `ResumeSessionResponse` carries `configOptions`, from the same source as session/new.

- [ ] cwd equality check, by whichever route shipped
- [ ] Composition reassembly and root-set replacement
- [ ] Cursor-shaped replay sending whole-message upserts
- [ ] Deleted-session failure path, catching the real error case
- [ ] Live restore through `restoreSession(id:recordingRoot:instructions:tools:)`
- [ ] `missingTools` reported to the client, not swallowed

## Acceptance Criteria
- [ ] Record a scripted two-turn session, then resume with `replayFrom: start`: the collector receives whole-message upserts with the original messageIds, no chunks, before the resume response completes
- [ ] Resume with a different cwd gives an error, and no session is left open
- [ ] Resume omitting `additionalDirectories` on a session that had extra roots rebuilds confinement with the cwd only, asserted because a file outside the cwd is now refused
- [ ] Resume after delete gives a clean protocol error, driven by catching the typed case and not a message string
- [ ] A resumed session continues the conversation, and its next turn sees the earlier context
- [ ] Resuming with `shell: false` newly set reports the missing shell verbs from `configurationReport`
- [ ] Resuming with changed instructions writes one `divergence` event; resuming with unchanged instructions writes none

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift` — harness, record-then-resume round trips in temp repos
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.