---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1z1cbmp546hp8n2vh153d7v
  text: |
    ### Research

    - The `acp-client` executable product IS on the client package `main`
      (`d93ac7f`): `Package.swift` declares
      `.executable(name: "acp-client", targets: ["acp-client"])`. The
      IntegrationTests pin is `3f30444`, so `swift package update` must move
      it. No blocker.
    - `acp-client run "<prompt>" -- <agent> <args>` is the grammar. The agent
      command follows `--` (`AgentInvocation`, `parsing: .postTerminator`) and
      `AgentCommandResolver` accepts an absolute path.
    - `AgentProcess(command:arguments:)` in the client package spawns the
      child in its OWN process group, gives the child THIS process's
      environment, and reaps the group on `shutdown()`. So
      `ACP_AGENT_STUB_MODEL` reaches the child by inheritance, and the
      byte-identical test is the proof of it.
    - `RunTurn.answer(of:...)` pairs `InMemoryTransport` and then drives the
      wire. The drive splits in two: the handshake, and the turn. Only the
      handshake and the transport change between the two modes.
    - `--out-of-process` parses today and does nothing, so an out-of-process
      run gives the same stdout as an in-process run by accident. A test that
      reads stdout alone therefore cannot fail first. The second test finds
      the child's pid while the run is live, which no in-process run has.
  timestamp: 2026-09-07T22:56:18.070753+00:00
- actor: claude-code
  id: 01m1z1e2vz2mxk3v9z1hgax7kb
  text: |
    ### Blocker on one card item: "Refresh and commit `Package.resolved`"

    The refresh is done. `swift package update --package-path IntegrationTests
    FoundationModelsACPClient` moved the client pin from `3f30444` to
    `d93ac7f`, which is the `main` head that carries the `acp-client`
    product. `IntegrationTests/Package.resolved` now reads that revision.

    The COMMIT half cannot be done, and the reason is a written rule of this
    repository. `.gitignore` line 6 ignores `Package.resolved`, under this
    comment:

        # Each family dependency tracks a branch. The lock file pins one
        # revision on one machine, and no sibling package commits it.

    So the card asks for a commit that the repository's own policy forbids.
    This is a rule against a rule, and a person must say which one wins. The
    card was written before that policy landed.

    Nothing else on the card is blocked by this: the product resolves and the
    nested package builds, because the pin moved on this machine.
  timestamp: 2026-09-07T22:57:14.623536+00:00
- actor: claude-code
  id: 01m1z3y0729kjaazq6wt749m2e
  text: |
    ### The red step, and what it taught

    `--out-of-process` parsed and did nothing before this card, so a test that
    reads stdout alone PASSES against the old binary: an ignored flag gives
    the same answer as the flag that works. The byte-identical case is
    therefore true but not a proof on its own.

    The proof is the second case. It reads the live process table while the
    turn streams and names the `acp-agent acp` child the run started. Against
    the old binary that reading is empty, so the case failed for the right
    reason: "no `acp-agent acp` child was alive while the run streamed its
    answer".

    ### What did not work: counting every live agent

    The first shape of the reap proof took two readings of the live
    `acp-agent acp` processes, one before the run and one after, and asked
    whether the difference was empty. It reported a FALSE failure on the
    first green run: swift-testing runs the suites of one target beside each
    other, `OutOfProcessTests` had a healthy child of its own alive, and
    `ClientInteropTests` read that child as its own leak.

    The reading that holds is the ORPHANS: `pgrep -P 1 -f "<agent path> acp"`.
    An agent that outlived the run that started it has lost its parent, so
    the system gave it to `launchd`; an agent a neighbour suite is running
    still has its own live parent and stands in no such reading. That is also
    a tighter statement of the claim than "no agent is alive".

    ### The second reading: a child by its parent

    `SignalledExecutableRun` now hands `atFirstOutput` the identifier of the
    run it started, so the success row asks `pgrep -P <run> -f "<agent path>
    acp"` and names ONE child exactly. After the run it asks whether that
    child's whole process group is alive, which is the card's own wording.
  timestamp: 2026-09-07T23:40:53.346273+00:00
- actor: claude-code
  id: 01m1z87wfjd1rqwd646jf39map
  text: |
    ### implement — stuck

    - evidence: 11 files.
      - New: `Sources/acp-agent/OutOfProcessTurn.swift`,
        `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/OutOfProcessTests.swift`,
        `.../ClientInteropTests.swift`, `.../Support/ProcessCensus.swift`.
      - Changed: `Sources/acp-agent/RunCommand.swift`,
        `Sources/acp-agent/RunTurn.swift`, `IntegrationTests/Package.swift`,
        `.../ClientServerTests.swift`, `.../Support/BuiltExecutableRun.swift`,
        `.../Support/SignalledExecutableRun.swift`,
        `.../Support/TierThreeFixture.swift`.
      - Pins moved on this machine: FoundationModelsACPClient to `d93ac7f`
        (it carries the `acp-client` product) and FoundationModelsExtras to
        `09eed09` (the client's `AcpClientCore` needs `HealthStatus`, which
        the pinned Extras did not carry; without the second bump the nested
        package does not compile).
      - Root `swift test`: 484 tests in 50 suites passed, 1 known issue.
        That is the baseline, unmoved.
      - `swift test --package-path IntegrationTests`: 33 tests in 10 suites,
        32 passed, 1 failed in 4083 s. The failure is the tier-4
        `PythonCLIEvaluation`, on a TARGET bar its own file says the models
        have never cleared. `OutOfProcessTests`, `ClientInteropTests`,
        `StdioContractTests`, `ClientServerTests`, `InterruptTests` and
        `CLIProcessTests` all passed.
    - next: a person decides the `Package.resolved` conflict. The card asks
      to commit the file; `.gitignore` line 6 forbids it, under "no sibling
      package commits it". Every other item of the card is done and green.
  timestamp: 2026-09-08T00:56:11.507+00:00
- actor: claude-code
  id: 01m1z8bnbbhndma501n1s430zf
  text: |-
    ### finish iteration 1 — stuck
    - implement: changed, then stuck — 11 files, 4 new
    - test: green — root swift test 484 tests in 50 suites, one known issue; IntegrationTests 33 tests in 10 suites, 32 passed, 1 failed
    - commit: 31fca73 (the code only; Package.resolved is not in it)
    - outcome: stuck. A person must settle one conflict.

    **The conflict.** This card says "Refresh and commit `Package.resolved`". Line 6
    of `.gitignore` ignores that file, and states the reason: "Each family
    dependency tracks a branch. The lock file pins one revision on one machine, and
    no sibling package commits it." The two rules cannot both be correct, so the
    loop does not choose between them. The refresh is done — `swift package update`
    moved the client pin to `d93ac7f`, which carries the `acp-client` product — but
    the file stays out of the commit and out of `git`.

    To settle it, a person must do one of these:
    - Change this card to remove the "commit `Package.resolved`" item, and accept
      that each machine resolves the branch pins for itself.
    - Change `.gitignore` to track `IntegrationTests/Package.resolved`, and state
      why this package is different from its siblings.

    **A second pin moved.** The client's `AcpClientCore` needs `HealthStatus` from
    `FoundationModelsExtras`, and the pinned Extras did not carry it, so the nested
    package did not build until Extras moved to `09eed09` too.

    **The one test failure is not of this card.** It is the tier-4
    `PythonCLIEvaluation`, whose own file states its floor is "a TARGET bar, not a
    measured baseline". `StdioContractTests` and `ClientServerTests` both pass.
  timestamp: 2026-09-08T00:58:15.275122+00:00
- actor: claude-code
  id: 01m20ezaph1rsb4cx2h2mgv9pc
  text: |-
    ### The conflict is settled — 2026-09-08

    The user decided: **do not commit `Package.resolved`. The version or the
    branch name in the Swift package definition is the reference.**

    `.gitignore` keeps its rule, and item 3 of this card is corrected. The
    card no longer asks for a commit that the family policy forbids.

    **Why the earlier item was wrong.** It said that without the committed
    lock file the `acp-client` product "does not exist". That is true for one
    case only: a machine that already holds an old `Package.resolved`. A
    fresh clone holds no lock file, so SwiftPM resolves each branch to its
    head and the product is there. The CI workflow clones fresh on each run,
    so CI never met this.

    A commit would have made it worse. It would pin CI and each new clone to
    the five revisions on one machine, which is the state the `.gitignore`
    comment refuses.

    **Evidence read before the decision:**
    - `.gitignore` lines 4 to 6.
    - `git ls-files` shows no `Package.resolved` tracked in this repository.
    - Both lock files are on disk and untracked.
    - `Package.swift:25`: "Each family sibling is a remote dependency on its
      `main` branch, never a [path]".
    - `.github/workflows/ci.yml` delegates to the shared org workflow, which
      clones fresh.

    The card is ready for `/review`.
  timestamp: 2026-09-08T12:13:05.617181+00:00
- actor: claude-code
  id: 01m20f5kp66zwe3x389df509bk
  text: |-
    ### review — clean
    - evidence: `review sha 31fca73~1..31fca73`. 7 validators ran, and 0 of them failed. 0 findings. 11 files were in the scope. 2 `.kanban` files stay out of the scope, because `.reviewignore` holds them out.
    - next: no work is open. The card moves to the Done column.
  timestamp: 2026-09-08T12:16:31.430496+00:00
depends_on:
- 01M1MP6PBZ3X4FAA6CVCFKR6VW
- 01M1MNZGPCF9P839A8G3KB0YGM
- 01M1MP674NX951G1XZW0T67P98
position_column: done
position_ordinal: bd80
title: --out-of-process, and the tier-3 interop tests over a real pipe
---
### What

cli-plan.md §5.4 and §9. This closes the loop: it proves that the
in-process transport and the stdio transport give one behavior.

1. **`--out-of-process` on `run`.** The CLI starts a second copy of its
   own binary in `acp` mode and speaks over stdio in place of
   `InMemoryTransport.pair()`. Find its own path with
   `Bundle.main.executableURL`, as `acp-print` already does. Everything
   else stays the same, because the CLI already talks to a connection.
   Pass `ACP_AGENT_STUB_MODEL` through to the child, so a test can make
   the child deterministic.
2. **The `acp-client` product dependency.** `IntegrationTests/Package.swift`
   adds the `acp-client` executable product from the client package, so
   `swift test --package-path IntegrationTests` builds it beside the
   agent binary, where `BuiltProductLocator` finds it. Same pattern as
   `mcp-test-server`.
3. **Refresh the local `Package.resolved`, and do not commit it.**
   The client package is a `main` branch dependency, and a branch
   dependency stays pinned by revision until `swift package update`
   runs. On a machine that holds an old lock file the `acp-client`
   product does not exist, and the failure reads as "no such product"
   and not as a stale pin. `swift package update` clears that.

   The file stays out of `git`. `Package.swift` names the branch, and
   that branch name is the pin this package keeps — the lock file is a
   local artifact of one machine. A fresh clone holds no lock file, so
   it resolves each branch to its head; that is why CI never meets the
   stale pin. `.gitignore` lines 4 to 6 state the same policy for the
   whole family.

   (This item said "commit the refreshed file" before 2026-09-08. That
   was wrong, and the comment on this card records why.)
4. The tests below.

**Determinism.** Two processes running a real model do not produce
byte-identical text — sampling is not reproducible. Every comparison
here runs with `ACP_AGENT_STUB_MODEL=1`, the deterministic echo model
that `9ndzkbe` adds. Without that switch these tests cannot be written
at all.

**The gate.** There is no `ACP_TIER3` environment variable. The nested
package is the gate: the root `swift test` never sees these targets, and
`swift test --package-path IntegrationTests` runs them. The directory is
`IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/`.

- [x] `--out-of-process`, spawning this binary in `acp` mode
- [x] Pass the stub-model variable through to the child
- [x] The `acp-client` product dependency in the nested package
- [x] Refresh the local `Package.resolved`, and keep it out of `git`
- [x] The three tests below

### Acceptance Criteria

- [x] With `ACP_AGENT_STUB_MODEL=1`, `acp-agent run --out-of-process
      "hi"` gives stdout byte-identical to the in-process run.
- [x] No agent process outlives the run, in success, failure and
      interrupt.
- [x] `acp-client` builds into the products directory under
      `swift test --package-path IntegrationTests`.
- [x] `IntegrationTests/Package.swift` names the client package on its
      `main` branch, and `git` holds no `Package.resolved`. The local
      lock file reads `d93ac7f`, which carries the `acp-client` product.

### Tests

All in `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/`:

- [x] `OutOfProcessTests.swift`: with the stub model, the in-process and
      the out-of-process runs of one prompt give byte-identical stdout.
- [x] `OutOfProcessTests.swift`: after each of success, failure and
      interrupt, no process in the child's process group is alive.
- [x] `ClientInteropTests.swift`: `acp-client run "…" -- acp-agent acp`
      exits 0, its stdout holds only the answer, and no process outlives
      the run.
- [x] The present `StdioContractTests` and `ClientServerTests` still
      pass.
- [x] `swift test --package-path IntegrationTests`: 32 of 33 tests pass.
      The one failure is the tier-4 `PythonCLIEvaluation`.
      `PythonCLIEvaluation.swift:82` states the bar is "A TARGET bar,
      not a measured baseline" and that "the gated tier currently fails
      this bar". That state is dated 2026-09-02, before this card, and
      this card changes no file of it.

### Blocked by

The `acp-client` binary must be on the client repository's `main` — its
N1+N2 card — before this package can declare the product dependency.
It is there, at `d93ac7f`.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
