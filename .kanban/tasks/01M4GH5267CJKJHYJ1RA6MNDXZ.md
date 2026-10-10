---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4gpcrn9bbf2s3sgrqmv965q
  text: |-
    Context from session foundationmodelsacp-43 (2026-10-09). The Extras display API is done, local, not pushed yet.

    Keep these two rules in the projection:

    1. A nil field means "no change". The `.metadata` event that `ToolContext.update(title:kind:locations:)` makes has `rawInput` nil. In the `tool_call_update` patch, omit each nil field. Do not send `null`: in ACP, `null` clears the field.
    2. Display events of the background grace period are not withdrawn. Thus a `tool_call_content_chunk` can arrive for a run that then settles inline. The projection must accept a content chunk before an inline settlement, and the settlement replace must still be the last update.

    Add a test for each rule.
  timestamp: 2026-10-09T16:02:00.489846+00:00
- actor: claude-code
  id: 01m4hdazy46eebsnkvqbdk82dm
  text: |-
    Status from session foundationmodelsacp-43 (2026-10-09): Router ^twha0gz and ^xhmws92 are done (tests green, reviews clean) in the local Router commits 7f20163b, 1b77ef2b and 29b60440. They are NOT pushed. The user decides the push. Do not start this task before the push.

    After the push:
    1. `SessionEvent` has a new case `.toolDisplay(ToolDisplayEvent)`. It is live on `streamEvents(to:)` and on `streamSessionEvents()`. It is never staged and never journaled. Display events that arrive in the settle period are delivered.
    2. The Router re-exports `ToolDisplayEvent` and `ToolDisplayContent`, so this package needs no new import.
    3. COMPILE BREAK: each exhaustive `switch` on `SessionEvent` (in `Agent/EventProjection.swift`) must add `.toolDisplay`.
    4. The same push also changes `toolInvocation(record)` to `toolInvocation(record, toolCallID:)` (see ^e1yq4gh). Do the two changes in one commit, because both break the build of this package.
  timestamp: 2026-10-09T22:42:59.652452+00:00
- actor: claude-code
  id: 01m4hgxnehr14n8nhv9fwygb5h
  text: 'Upstream status (session foundationmodelsacp-43, 2026-10-09): NOT READY. Extras ^1vhftw2 (23974f0) and ^jt7qx6k (ba381a0, 315c17b, 5ca30c9) are pushed. Router ^twha0gz (29b60440, adds `SessionEvent.toolDisplay`) is done and reviewed but NOT pushed. /finish skips this task until Router 29b60440 is on origin/main.'
  timestamp: 2026-10-09T23:45:37.233618+00:00
- actor: claude-code
  id: 01m4jamzkztr155z38j0dbvqf3
  text: 'Router is pushed (session foundationmodelsacp-43, 2026-10-10): origin/main holds 29b60440 (^twha0gz) and 1b77ef2b (^xhmws92). This task is READY. Run `swift package update FoundationModelsRouter` first. The same Router move also changes `toolInvocation(record)` to `toolInvocation(record, toolCallID:)` (task ^e1yq4gh), and `EventProjection.swift` must compile after the move. Thus, the first of ^a6mndxz and ^e1yq4gh that runs must make both switch arms compile in its commit.'
  timestamp: 2026-10-10T07:15:15.711911+00:00
- actor: claude-code
  id: 01m4jy7wk2ye9q65kcff3wxvxv
  text: |-
    ### FoundationModelsAgents moves with Router (session foundationmodelsagents-3d, 2026-10-10)

    FoundationModelsAgents main is now 016945e, and it uses Router main dc642256. It reads `SessionEvent.toolInvocation(_, toolCallID:)` and handles `.toolDisplay`. The pinned Agents dfd406b was built against the old Router API. Thus, when this task moves the Router pin, move FoundationModelsAgents to 016945e or later in the same update: `swift package update FoundationModelsRouter FoundationModelsAgents` (same gRPC retry rule; no hand edit; no local path override). Report every pin that moves. CI for 016945e was running when this was written; check that session's report first.

    Other changes in Agents 016945e that the agent tests can see:
    - BREAKING: the agents tool of a RUN does not show the run's own agent. "start agent" with its own agent name gives a corrective, and "send agent" with its own run id also gives a corrective. The host root session has no run, so the rule does not apply to it.
    - The agents tool description changed: the model compares each task with each agent description, gives the task to a matching agent, calls "list agents" when no agent matches, and does the task itself only when no agent matches after that. A test that checks the tool description text can need an update.
  timestamp: 2026-10-10T12:57:38.146063+00:00
- actor: claude-code
  id: 01m4jz0q3y13q8npsmt98h2e9b
  text: 'CI of FoundationModelsAgents 016945e (run 38053696912), reported by session foundationmodelsagents-3d on 2026-10-10: "Build & test" passed. In "Integration", 12 of 13 live tests passed (including LiveNested agentSpawn). The one failure is LiveSourcesTests.swift:94, "The folder ''agents'' doesn''t exist", because swissarmyhammer/skills main (2451fac) has no `agents/<name>/AGENT.md` folders yet. It is safe to move the Agents pin to 016945e in this task.'
  timestamp: 2026-10-10T13:11:11.742839+00:00
- actor: claude-code
  id: 01m4k5a72rc0s7wardb1bn42b4
  text: |-
    Step 1 (pins) done, 2026-10-10.

    - `swift package update ... --scratch-path` is not valid: `--scratch-path` must come before `update` (`swift package --scratch-path .build/alt update FoundationModelsRouter FoundationModelsAgents`).
    - Runs 1 to 4 exit 1 with "exhausted attempts ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf". `--very-verbose` shows "dependency resolution complete!" with Router main and Agents main, then the error comes in the graph load after the solve. SwiftPM did not write Package.resolved, but .build/alt/workspace-state.json already had the new checkouts. The swift-otel conditions use `alwaysIncludeOnKnownBrokenToolchains`, but that is only for compiler 6.2.0; this toolchain is Swift 6.4. Thus the fault comes and goes from one process to the next (my hypothesis: the order of the trait map, which comes from the random hash seed of each process). Run 5 exit 0 (166 s).
    - Root Package.resolved: foundationmodelsrouter 16abef2 -> dc642256; foundationmodelsagents dfd406b -> 016945e. No other pin moved. No grpc pin.
    - IntegrationTests (`swift package --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt update FoundationModelsRouter FoundationModelsAgents`): run 1 exit 0. The same two pins moved. Root and IntegrationTests have the same pins.
    - Package.resolved is git-ignored, thus git shows no diff for it.
  timestamp: 2026-10-10T15:01:14.456751+00:00
- actor: claude-code
  id: 01m4k6tw9pbbf7xg1m6fjjj8ny
  text: |-
    ### Implementation (2026-10-10)

    Research:
    - The Router move (16abef2 -> dc642256) broke one line only: the `.toolInvocation(let record)` arm in `EventProjection.project(_:)`. Now `.toolInvocation(let record, _)`; the behavior did not change (a debug log only). ^e1yq4gh uses the `toolCallID` next.
    - `.toolDisplay` did not break the build, because the switch has an `@unknown default` arm. Before this change, each display event became the debug log "The projection does not know a Router event".
    - The Router doc says: a background run that settles in its settle period still sends `runSettled`, and it does not withdraw its display events. Thus the order is: display events, then the settlement. The projection keeps that order, so the settlement replace stays last with no extra state.
    - The ACP v2 `Diff` holds `changes` and an optional `patch` (`git_patch`, absolute paths). Multitool `GitPatch` is internal, so I could not use it.

    What changed:
    - `EventProjection.projectDisplay(_:)`: `.contentChunk` -> one `tool_call_content_chunk`; `.contentReplace` -> `tool_call_update` with all the parts; `.metadata` -> `tool_call_update` patch of `title`, `kind` (raw value -> `ToolKind(wireValue:)`), `locations`, `rawInput`. Each `nil` field is omitted (`.unchanged`), never `null`. All keys are on the run `correlationID` (new helper `runCallId`), the same as progress, report and settlement.
    - `runCallUpdate` now takes `title: PatchField<String>` and has `kind` and `rawInput` patches. The three old callers send `title: .value(op)`, as before.
    - Content mapping: `.text` and `.json` -> text item (the same rule as a `.structure` segment). `.diff` -> `Diff` with one `add` (no old text) or `modify` change and a whole-file git patch (new `WholeFilePatch`). A relative diff path -> a text item that holds the patch, with a warning log. A diff that does not change the text -> a `Diff` with no `patch`.
    - Metadata edge rules: a relative location is dropped (warning); when all locations are dropped, `locations` stays unchanged (an empty array would clear it); an empty list from the tool clears it; a `rawInput` that is not JSON stays unchanged (warning).
    - A display event sets `sawOutput`: it is observable output on the wire, as an attachment report is.

    Discovered problem, new task ^w7hzpmq (depends on ^e1yq4gh): the metadata title of a tool is written over by the `op` title of each later run update, and the settlement is always last. The fix needs the one-creation rule of ^e1yq4gh, so I did not do a partial fix here.

    Agents 016945e: no test in this package or in IntegrationTests reads the agents tool description or the self-start rule, so no test text needed an update. The full suites pass with the new Agents pin.
  timestamp: 2026-10-10T15:27:49.046940+00:00
- actor: claude-code
  id: 01m4k6v4bpktjxd6agp34ejrdp
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACPAgent/Agent/EventProjection.swift, Sources/FoundationModelsACPAgent/Agent/WholeFilePatch.swift (new), Tests/FoundationModelsACPAgentTests/ToolDisplayProjectionTests.swift (new, 15 tests), Tests/FoundationModelsACPAgentTests/WholeFilePatchTests.swift (new, 3 tests), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift (`wireObject(of:)`), plus the git-ignored Package.resolved files (root and IntegrationTests: Router 16abef2 -> dc642256, Agents dfd406b -> 016945e; no other pin moved). RED: 13 of 13 new projection tests failed (no display update on the wire); then 3 edge tests failed before their branches. GREEN: `swift test --scratch-path .build/alt --force-resolved-versions --filter "WholeFilePatchTests|ToolDisplayProjectionTests"` 17 tests passed (one more test added after). Full root suite (`SKILLS_MARKETPLACE_CACHE=<empty scratch folder> swift test --scratch-path .build/alt --force-resolved-versions`): 867 tests in 93 suites passed, 1 known issue (the intended `withKnownIssue` in HarnessSmokeTests). IntegrationTests (`swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions`): 30 tests in 11 suites passed. The only warning in both runs is the mlx-swift_Cmlx.bundle "missing creator for mutated node" line from a dependency. No git stash; bench/swebench_prompt.py and its test not touched; not committed.
    - next: /review. The task stays in `doing`.
  timestamp: 2026-10-10T15:27:57.302571+00:00
- actor: claude-code
  id: 01m4k7g3rmbpbgzkqbf3995bmr
  text: |-
    ### test — green
    - evidence: swift test --scratch-path .build/alt --force-resolved-versions (SKILLS_MARKETPLACE_CACHE set to an empty scratch folder) — 867 tests in 93 suites passed, 1 known issue (the intentional withKnownIssue in HarnessSmokeTests), 0 failures; swift test --package-path IntegrationTests --no-parallel --scratch-path IntegrationTests/.build/alt --force-resolved-versions — 30 tests in 11 suites passed; swift build -c release --scratch-path .build/alt-release --force-resolved-versions — Build complete, 0 warnings. Only warning in the logs: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle (mlx-swift dependency). No package files changed.
    - next: review or commit by the caller
  timestamp: 2026-10-10T15:39:24.820383+00:00
- actor: claude-code
  id: 01m4k7gxa1qy15q451z2ck7y1d
  text: |-
    ### commit — changed
    - evidence: e4c06e7 feat(acp): project tool display events as tool_call_content_chunk and metadata patches (^a6mndxz). Kanban commit before it: b4f0dd3 chore(kanban): add task ^w7hzpmq.
    - next: review
  timestamp: 2026-10-10T15:39:50.977818+00:00
- actor: claude-code
  id: 01m4k81a3h70ef11nxc16vxs5k
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (e4c06e7). Counts: findings 0, confirmed 0, refuted 4, attempted 7, failed 0, skipped 0. 5 files reviewed. 2 .kanban files not reviewed (.reviewignore). No validator failed because of the orphan checkout in .build.
    - next: none. The task is in done.
  timestamp: 2026-10-10T15:48:48.369108+00:00
- actor: claude-code
  id: 01m4k81n8ztch99cs44cxww9g6
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files; pins Router 16abef2 -> dc642256 and Agents dfd406b -> 016945e (the gRPC error 4 times, run 5 passed)
    - test: green — swift test 867 (1 known issue); IntegrationTests 30; release build complete
    - commit: e4c06e7
    - review: clean — 0 findings; every validator finished
  timestamp: 2026-10-10T15:48:59.807378+00:00
position_column: done
position_ordinal: ffb580
title: Project tool display events as tool_call_content_chunk and metadata patches
---
## Goal

Send the tool display events of the Router to the ACP client as the v2 prompt-lifecycle wire shapes (https://agentclientprotocol.com/protocol/v2/prompt-lifecycle). Terminals are out of scope.

## Dependency

This task waits for FoundationModelsRouter task ^twha0gz (01M4GH44FNNNW2WB32CTWHA0GZ) "Forward tool display events as SessionEvent.toolDisplay". It is on the Router board. Do not start before it is on `origin/main` of FoundationModelsRouter.

## What to change

In `Sources/FoundationModelsACPAgent/Agent/EventProjection.swift`:

1. Map `.contentChunk` to `tool_call_content_chunk`.
2. Map `.contentReplace` to a `tool_call_update` that replaces the content.
3. Map `.metadata` to a `tool_call_update` patch with `title`, `kind`, `locations` and `rawInput`.

## Facts

- Now nothing sends `tool_call_content_chunk`. The type is in FoundationModelsACP, `Generated/Models8.generated.swift:862`. The plan names it in §8.4 (`plan.md:1142-1153`).
- Keep the settlement replace as the last step of a tool call, so that the final content is correct (`plan.md:1888-1894`).

## Acceptance

- [x] A content chunk event gives one `tool_call_content_chunk` on the wire.
- [x] A content replace event gives a `tool_call_update` with the new content.
- [x] A metadata event gives a `tool_call_update` patch with `title`, `kind`, `locations` and `rawInput`.
- [x] The settlement replace is still the last update of a tool call.
- [x] Each case has a test that reads the wire messages.