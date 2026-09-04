---
assignees:
- claude-code
depends_on:
- 01M1MP6PBZ3X4FAA6CVCFKR6VW
- 01M1MNZGPCF9P839A8G3KB0YGM
- 01M1MP674NX951G1XZW0T67P98
position_column: todo
position_ordinal: '9380'
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
3. **Refresh `Package.resolved`.** The client package is a `main` branch
   dependency, and a branch dependency stays pinned by revision until
   `swift package update` runs. Without the bump the `acp-client`
   product does not exist, and the failure reads as "no such product",
   not as a stale pin. Commit the refreshed file.
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

- [ ] `--out-of-process`, spawning this binary in `acp` mode
- [ ] Pass the stub-model variable through to the child
- [ ] The `acp-client` product dependency in the nested package
- [ ] Refresh and commit `Package.resolved`
- [ ] The three tests below

### Acceptance Criteria

- [ ] With `ACP_AGENT_STUB_MODEL=1`, `acp-agent run --out-of-process
      "hi"` gives stdout byte-identical to the in-process run.
- [ ] No agent process outlives the run, in success, failure and
      interrupt.
- [ ] `acp-client` builds into the products directory under
      `swift test --package-path IntegrationTests`.
- [ ] `Package.resolved` names a client revision that carries the
      `acp-client` product.

### Tests

All in `IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/`:

- [ ] `OutOfProcessTests.swift`: with the stub model, the in-process and
      the out-of-process runs of one prompt give byte-identical stdout.
- [ ] `OutOfProcessTests.swift`: after each of success, failure and
      interrupt, no process in the child's process group is alive.
- [ ] `ClientInteropTests.swift`: `acp-client run "…" -- acp-agent acp`
      exits 0, its stdout holds only the answer, and no process outlives
      the run.
- [ ] The present `StdioContractTests` and `ClientServerTests` still
      pass.
- [ ] `swift test --package-path IntegrationTests` passes.

### Blocked by

The `acp-client` binary must be on the client repository's `main` — its
N1+N2 card — before this package can declare the product dependency.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.