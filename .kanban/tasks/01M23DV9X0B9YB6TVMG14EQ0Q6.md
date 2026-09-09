---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m23eqdhp49sqjwefdvfmm8kt
  text: |-
    Research done. The answer to "read where the directory must come from":

    Router facts (read in the FoundationModelsRouter checkout):
    - `Router.init(recordingsDir:)` picks the sink: `JSONLRecorder(directory:)` when the value is set, `NoneRecorder()` when it is `nil` (Router.swift, `defaultRecorder(recordingsDir:)`).
    - `RoutedLLM.recordingDirectory(forSessionId:recordingRoot:)` returns `<recordingRoot>/<sessionId>/` when the session names a root. So the per-session root alone fixes the write path.
    - `recordingsDir` does two more things: it is the root `JSONLRecorder.ensureRootOwnership()` locks, and it gates `makeDurableRecording`, which writes the `session.json` sidecar.
    - `Router.recorder` and `Router.recordingsDir` are internal, `JSONLRecorder` is `package`, and `NoneRecorder` is internal. No test in this package can read back which recorder a router holds. A test must assert on behaviour: run a session and read the file.

    The decision: `AgentComposition.compose` gives the router the recording root of its OWN working directory — `configuration.transcripts.location.recordingRoot(workingDirectory:name:userDirectory:)`, with the user layer root taken from `loader.stack`. Reasons:
    1. In `run` mode the session cwd is the composition cwd, so the router root and the session root are the same directory. The lock and the writes agree.
    2. In `acp` mode each session still overrides the destination with its own root, so a session in another cwd records in the correct place.
    3. It is the same directory `acp-agent doctor` reports, so the report and the writer cannot disagree.

    The user layer root: `SessionSetup.userLayerRoot(of:)` is internal to the library, so the CLI cannot call it. A new public overload `TranscriptLocation.recordingRoot(workingDirectory:name:stack:)` in this package forwards to the existing method through that one helper, so no copy of the user-layer rule is added.

    Test plan:
    - Unit: compose over the stub path, run one turn, then read `<workspace>/.acp-agent/transcripts/<sessionId>/transcript.jsonl` with the existing `RecordedTranscriptFile` reader.
    - Cause: take `composed.agent.residentProfile.standard`, make a session with a recording root, respond once, and assert the file appears. This reads the recorder the composed router holds, and not the agent's session plumbing.
    - Tier 3: `acp-agent run --cwd <dir>` over the built binary with `ACP_AGENT_STUB_MODEL=1`, then read the same file from the spawned process's own directory.
  timestamp: 2026-09-09T16:06:29.686327+00:00
- actor: claude-code
  id: 01m23fhxntww0sqbvks1dg7jb3
  text: |-
    The first attempt gave the router the project's own transcripts root. It worked, and it was wrong. Three findings turned it back:

    1. A tier-3 run left `IntegrationTests/.acp-agent/transcripts/owner.lock` in the repository. The out-of-process child starts in the directory the test process runs in, so that directory became a recording root.
    2. `JSONLRecorder.ensureRootOwnership()` locks the router root and drops every event when the lock is held. Two `acp-agent` processes in one project would then contend, and the loser would record nothing, silently.
    3. `ToolCatalog` opens the librarian session with `profile.flash.makeSession(instructions:)`, which names no recording root. Such a session records under the ROUTER root. With the project root, `TranscriptStore.mergedEvents` would read librarian sessions out of the project's own transcripts.

    The router root is now a fresh throwaway directory under the temporary directory, one for each composition — the same shape the tier-4 eval uses. The public `TranscriptLocation.recordingRoot(workingDirectory:name:stack:)` overload that the first attempt added is reverted; no library file changes.

    Red-then-green proof. Each new case was run against the code before the fix, and again after it.

    Before (production file stashed, tests kept):
    - `swift test --filter 'AcpCommandTests|AgentCompositionTests'` — 9 tests, 6 issues. `theComposedTurnRecordsTheSessionTranscript` 3 issues, `theComposedRouterRecordsThroughItsResidentProfile` 1 issue, `aTurnOverTheStdioWireRecordsTheSessionTranscript` 2 issues.
    - `swift test --package-path IntegrationTests --filter TranscriptRecordingTests` — 2 tests, 3 issues. Both cases failed because the recording root held no session directory.

    After:
    - `swift test` — 558 tests in 60 suites passed, 1 known issue, which stands in `HarnessSmokeTests` and predates this card.
    - `swift test --package-path IntegrationTests --filter TranscriptRecordingTests` — 2 tests passed.
    - `swift test --package-path IntegrationTests --filter 'TranscriptRecordingTests|StdioContractTests|OutOfProcessTests|ClientInteropTests|InterruptTests'` — 8 tests in 5 suites passed, and no stray dotfolder is left in the repository.

    Two things found on the way, recorded on card ^bah727b:
    - `IntegrationTests/Package.resolved` pinned an older Router and the tier-3 package did not compile. A local `swift package update` fixed it. The file is git-ignored, so it is not part of this change.
    - `CLIProcessTests.aStubSubcommandExitsOneAndSaysSoOnStderr` expects `doctor` to answer "is not implemented yet". The doctor card landed long ago. The case fails, and it fails without this change.
  timestamp: 2026-09-09T16:20:58.170885+00:00
- actor: claude-code
  id: 01m23fj3chtk2w278ptvz3vryq
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/acp-agent/AgentComposition.swift, Tests/FoundationModelsACPAgentTests/AgentCompositionTests.swift, Tests/FoundationModelsACPAgentTests/AcpCommandTests.swift, Tests/FoundationModelsACPAgentTests/Support/ComposedTurnFixture.swift, Tests/FoundationModelsACPAgentTests/Support/RecordedTranscriptFile.swift, IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/TranscriptRecordingTests.swift (new). Red before the fix: 6 issues over 3 unit cases, 3 issues over 2 tier-3 cases. Green after: 558 unit tests pass with 1 pre-existing known issue, and the tier-3 suite passes.
    - next: /review
  timestamp: 2026-09-09T16:21:04.017171+00:00
position_column: doing
position_ordinal: '80'
title: 'acp-agent writes no transcript: AgentComposition gives Router no recordings directory'
---
## The defect

Every session of the `acp-agent` CLI records no event. `transcript.jsonl` is
never written, in `run` mode and in `acp` mode, on the live path and on the
stub path.

`Sources/acp-agent/AgentComposition.swift:239` makes the router of each
mode. Neither branch gives a recordings directory:

```swift
private static func makeRouter(
    for modelSource: ModelSource, pacedBy chunkDelay: Swift.Duration?
) throws -> Router {
    switch modelSource {
    case .live:
        Router(
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()))
    case .stub:
        EchoModel.makeRouter(
            cacheDirectory: try makeStubCacheDirectory(),
            loader: makeStubLoader(pacedBy: chunkDelay))
    }
}
```

Router says what that gives (`Router.swift:1229`):

> The default recorder: JSONL under `recordingsDir` when set, else the no-op
> sink.

So the CLI holds a `NoneRecorder`. Each
`recorder.append(partial, to: recordingDirectory)` at
`RoutedSessionActorRecording.swift:331` goes to the no-op sink. A `grep` of
`Sources/` finds no `recorder` and no `.jsonl(` in this package.

## The evidence

A live SWE-bench run on 2026-09-09, session `01M23C9E4GP7J9CWD06WPQHWYX`, 15
minutes into one turn:

```
repo/.acp-agent/transcripts/sessions.jsonl     written, and correct
repo/.acp-agent/transcripts/.gitattributes     written
repo/.acp-agent/transcripts/<sessionULID>/     ABSENT
```

The turn had started: `recordSessionMetaIfNeeded()` runs at
`RoutedSessionActorTurnExecution.swift:57`, immediately after `beginTurn()`,
and `JSONLRecorder` makes the directory at the first append. The directory
must exist one second after the turn starts. It does not exist.

## What it breaks

- `--resume` and `session/load` have nothing to read.
- `acp-agent` keeps no record of what the model did.
- The transcripts rows of `acp-agent doctor` report a directory that no
  session ever fills.

## The fix

- [x] `AgentComposition.makeRouter` gives a recordings directory on the
      `.live` branch, the way the tier-4 eval does at
      `PythonCLIEvaluation.swift:312`.
- [x] The `.stub` branch gives one too: `EchoModel.makeRouter` already takes
      `recordingsDirectory:`, and the CLI does not use it.
- [x] Read where the directory must come from. Each session takes its own
      recording root from the `transcripts.location` of its configuration
      (`TranscriptLocation.project` by default), and `SessionSetup` gives
      that root to `makeSession(recordingRoot:)`. So the router-level
      directory is the switch that turns the recorder ON; the per-session
      root selects the destination. Record the answer on this card before
      you change the code.

      The answer: the router root is a fresh throwaway directory under the
      temporary directory, one for each composition —
      `AgentComposition.makeRecordingsDirectory()`. It is the switch, and
      never a destination. The comments record the three reasons. A first
      attempt gave the project's own transcripts root instead; the comments
      record why that attempt was wrong.

## Why no test caught it

Three causes, and each one is necessary to the miss.

- [x] **Every transcript test makes its own router.**
      `StubProfileFixtures.swift:46`, `TranscriptRecordingFixtures.swift:112`,
      `SessionSetupTests.swift:51`, `MultiRootConfinementTests.swift:76`,
      `PythonCLISubjectTests.swift:133` and the tier-4
      `PythonCLIEvaluation.swift:312` each construct
      `Router(recordingsDir:)` or `EchoModel.makeRouter(recordingsDirectory:)`
      directly. Not one goes through `AgentComposition.makeRouter`. The one
      call site that ships is the one call site no test uses.
- [x] **The tests that DO compose never look at a recording.**
      `AcpCommandTests.swift:131` and `RunCommandTests` call
      `AgentComposition.compose`, but
      `RunCommandTests.oneSessionId(of:)` reads `composed.agent.sessions` —
      the dictionary in memory, and not the disk.
- [x] **The index hides the fault.** `sessions.jsonl` and `projects.jsonl`
      come from this package's `SessionIndex` and `ProjectRegistry`, and they
      do not use the Router recorder. A check of "the session was recorded"
      that reads the index passes while every event goes to the no-op sink.
      This is what the disk showed: the index correct, the events absent.

## The tests to add

- [x] A unit test over `AgentComposition.compose` on the stub path: one turn,
      then assert that `<recording root>/<sessionId>/transcript.jsonl` exists
      and holds the events of that turn. This test must fail before the fix.
      — `AgentCompositionTests.theComposedTurnRecordsTheSessionTranscript`.
- [x] A test that reads the recorder of the composed router, so the assertion
      names the cause and not only the symptom.
      — `AgentCompositionTests.theComposedRouterRecordsThroughItsResidentProfile`
      drives a session of the composed router's own resident profile, around
      the agent's session pipeline. Router keeps `Router.recorder` internal
      and `JSONLRecorder` `package`, so no test in this package can read the
      recorder type back; a behavioural assertion is the only one available.
- [x] A tier-3 test over the built binary: `acp-agent run --cwd <dir>` with
      the stub model, then read `<dir>/.acp-agent/transcripts/<id>/transcript.jsonl`.
      A test at this level cannot pass with a `NoneRecorder`.
      — `TranscriptRecordingTests` in the `IntegrationTests` package.
- [x] Never assert the recording through `sessions.jsonl` alone. The index is
      written on a path that does not touch the recorder, so it is a false
      witness. No new case reads the index.

## Done when

- [x] `acp-agent run` writes `transcript.jsonl` with the events of the turn.
- [x] The same is true in `acp` mode, and on the stub path.
      — `AcpCommandTests.aTurnOverTheStdioWireRecordsTheSessionTranscript`.
- [x] `--resume` continues a session that a previous `run` recorded.
      — `TranscriptRecordingTests.resumeContinuesTheSessionTheFirstRunRecorded`.
- [x] The new tests fail on the code before the fix, and pass after it.
