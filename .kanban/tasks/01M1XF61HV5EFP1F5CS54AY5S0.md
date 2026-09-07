---
assignees:
- claude-code
position_column: todo
position_ordinal: 9c80
title: 'Router: make resolve honour Task cancellation, so Ctrl-C can stop a download'
---
### What

`FoundationModelsRouter`'s `Router.resolve(profile:reporting:)` does not
honour Task cancellation. A caller that cancels the task keeps waiting
until the whole sizing, download and load pipeline ends. For a 15 GB
profile that is many minutes.

This card was raised out of `^0t67p98` ("Interrupt: Ctrl-C sends
session/cancel and exits 4"). cli-plan.md §5.9 claimed that the first
`Ctrl-C` stops a resolution and exits 4. The runtime cannot do that
today, so `^0t67p98` dropped the download case and this card carries
it.

### The evidence

Read at the revision `FoundationModelsACPAgent` pins in
`.build/checkouts/FoundationModelsRouter`:

- `Sources/FoundationModelsRouter/Router.swift` holds zero occurrences
  of `Task.checkCancellation()`, `Task.isCancelled` and
  `withTaskCancellationHandler`.
- The count is zero as well in every file of `Resolution/`, `Sizing/`,
  `Core/` and `Concurrency/`.
- Every cancellation check the package has is in `Session/` and in
  `Hosting/ToolRun.swift` — the turn path, not the resolve path.
- `AsyncSemaphore`, the single-flight gate of the resolve, has no
  cancellation handler, so a cancelled task that waits on it keeps
  waiting.

### The work, in the Router repository

- [ ] Check for cancellation between the stages of `runResolve`:
      sizing, metadata read, each acquire, each preload.
- [ ] Give `AsyncSemaphore.wait()` a cancellation path, so a cancelled
      waiter leaves the queue and throws `CancellationError`.
- [ ] Carry cancellation into the download: the loader must stop the
      transfer and leave the part files in the Hugging Face cache.
      Remove nothing on the way out, so the next run continues.
- [ ] Report the resolve as cancelled through `ResolutionProgress`, so a
      frontend can draw the end of the bar.

### The work, back in this repository

- [ ] Return the download paragraph to cli-plan.md §5.9.
- [ ] Extend `InterruptHandler` to the resolve window: a `SIGINT` before
      the wire opens cancels the composition task and exits 4.
- [ ] A test that a `SIGINT` during a resolve exits 4, and that the part
      files stay in the cache.

### Acceptance Criteria

- [ ] A cancelled task in `Router.resolve(profile:reporting:)` throws
      `CancellationError` inside a named time limit.
- [ ] The partly downloaded files stay in the Hugging Face cache after a
      cancelled resolve.
- [ ] `acp-agent` exits 4 on a `SIGINT` during a download.
