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

**The upstream block is LIFTED.** Router published the restore surface on `main` at commit `587cfe7` (2026-08-31). Verified against their source. This task now waits only on its own dependencies.

## The API, verified

`Sources/FoundationModelsRouter/Recording/SessionRestoration.swift`

```swift
public func restoreSession(
    id: ULID,
    recordingRoot: URL? = nil,
    instructions: String? = nil,
    tools: [any Tool] = []
) async throws -> RestoredSession

public func recordedWorkingDirectory(
    ofSession id: ULID, recordingRoot: URL? = nil
) throws -> URL          // NOTE: synchronous, not async
```

`RestoredSession` carries `session: RoutedSession`, `configurationReport: SessionConfigurationRestorationReport` and `contextMismatches: [RestoredSession.ContextMismatch]`. `ContextMismatch` holds `session: ULID`, `recorded: Int`, `resolved: Int` — the recorded working context against the live resolution.

Public: `restoreSession`, `recordedWorkingDirectory`, `RestoredSession`, `RestoredSession.ContextMismatch`, `SessionConfigurationRestorationReport` and its `MissingTool`, `SessionTreeRestorationError`, `TranscriptTreeError`. `restoreSessionTree` and `RestoredSessionTree` stay internal, as we asked.

## Three details that decide the implementation

**1. Check the cwd BEFORE restoring.** Router added `recordedWorkingDirectory(ofSession:recordingRoot:)` for us. It loads the tree and nothing else — no backend, no session, no write — and it is **synchronous `throws`**, so it needs no await. Call it first, compare against the resume `cwd`, and error on a mismatch. Do not restore and then reject; that builds a whole session in order to throw it away.

**2. A missing session raises `TranscriptTreeError.sessionNotFound`, NOT `SessionTreeRestorationError`.** Both are public, and `recordedWorkingDirectory` raises the same case, so the deleted-session path errors at the cheap pre-check. `SessionTreeRestorationError` covers restore-specific failures such as a non-root id. Catch the typed case; never match a message string.

**3. The instructions override applies to the NAMED ROOT only.** A recorded fork keeps its own recorded instructions. That suits us, because `restoreSession(id:)` releases those forks anyway and we never address a fork over ACP. A live fork taken later from the restored root does inherit the supplied string.

## Why the override exists, and the trap it closed

Without it, restore re-applies the recorded instructions and says nothing. Our §7.4 reassembles instructions from the current config layer, the AGENTS.md walk and the preloaded skill bodies, so that work would have gone nowhere and the session would have run on the stale recorded string.

Upstream's first implementation of the fix was itself broken in the same shape: it set a `RoutedSessionActor.instructions` property that no generation path reads, because the restore path calls `container.makeSession(transcript:tools:)`, which takes no instructions argument — the SDK reads them from the transcript's leading `.instructions` entry. Their review caught it and fixed it at the transcript seam rather than documenting it. **Do not assume a supplied value reached the model because a property holds it.** Assert on behavior.

## The divergence event

Supplying instructions that differ from the recorded ones appends one `TranscriptEvent` of kind `.divergence`, carrying a stable phrase plus both character counts, with neither body and no hash. `nil` or an identical string writes nothing. Nothing is added to the return value for it — the audience is whoever reads the committed transcript later, not the caller.

Assert it through `TranscriptEvent.kind == .divergence`, and pin the text against `RestoredSession.instructionsDivergencePhrase`, which upstream made public at their commit `6be2294`. Name the symbol; never copy the literal into our source. The phrase is the documented grep target for a repository of committed transcripts, so a saved grep breaks if it drifts — pinning the symbol is what makes that drift a compile error rather than a silent miss.

## The work

`session/resume(sessionId, cwd, mcpServers, additionalDirectories, replayFrom)`:

- `cwd` MUST equal the recorded original, checked with `recordedWorkingDirectory` before any restore. A mismatch gives an error, never a silent re-root.
- Reassemble our side from the recorded cwd: the config layer, the instructions, the tools and the confinement. Reconnect the config and client MCP servers. The client list is authoritative on each reconnect and is never persisted.
- Pass the freshly assembled instructions as `instructions:`. Pass the roster as `tools:`; Router matches by recorded name and we supply the instances.
- **Report `configurationReport.missingTools` to the client. Do not swallow it.** Resume is where our roster legitimately differs from the recording: `shell: false` newly set, an MCP server that failed to connect, a replaced `additionalDirectories` set, a deleted skill.
- `additionalDirectories` is authoritative and replaceable. A non-empty list is the complete new root set. Omitted or empty means no additional roots. Never inherit former roots. Persist the new ordered list to the index.
- Replay: `replayFrom: {"type": "start"}` replays before the response returns. Omitted or null means no replay. Replay sends whole-message upserts (`user_message`, `agent_message`, `agent_thought`) with the original `messageId` values, never `*_chunk`, so a client that saw chunks converges through §8.3's replace row. Replay reads the full recorded history; fold checkpoints are not messages and are not sent. Write the replay path with `ReplayFrom` as an inclusive cursor parameter.
- `ResumeSessionResponse` carries `configOptions`, from the same source as session/new.

- [ ] cwd equality check through `recordedWorkingDirectory`, before restore
- [ ] Composition reassembly and root-set replacement
- [ ] `restoreSession(id:recordingRoot:instructions:tools:)` with fresh instructions
- [ ] `missingTools` reported to the client
- [ ] Cursor-shaped replay sending whole-message upserts
- [ ] Deleted-session path catching `TranscriptTreeError.sessionNotFound`

## Acceptance Criteria
- [ ] Record a scripted two-turn session, then resume with `replayFrom: start`: the collector receives whole-message upserts with the original messageIds, no chunks, before the resume response completes
- [ ] Resume with a different cwd errors, and no session was constructed — assert the scripted loader was never asked for a backend
- [ ] Resume after delete gives a clean protocol error, driven by catching `TranscriptTreeError.sessionNotFound`
- [ ] Resume omitting `additionalDirectories` on a session that had extra roots rebuilds confinement with the cwd only, asserted because a file outside the cwd is now refused
- [ ] A resumed session continues the conversation, and its next turn sees the earlier context
- [ ] Resuming with `shell: false` newly set reports the missing shell verbs from `configurationReport`
- [ ] **Resuming with changed instructions makes the MODEL see them** — assert through the scripted backend's received transcript, not through any property that holds the string
- [ ] Resuming with changed instructions writes one `.divergence` event; resuming with unchanged or nil instructions writes none

## Tests
- [ ] `Tests/FoundationModelsACPAgentTests/SessionResumeTests.swift` — harness, record-then-resume round trips in temp repos
- [ ] `swift test` → green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.