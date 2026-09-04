---
assignees:
- claude-code
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: todo
position_ordinal: 8f80
title: 'doctor checks: the profile — model ids, memory fit, disk and MTP'
---
### What

cli-plan.md §5.12, row 2. This is the row that earns the whole command.
A wrong model repository id and a profile that does not fit the machine
are the two failures a person cannot diagnose from the error Router
raises.

`ProfileDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`profile`. **Every external fact it needs is injected**: a resolver
protocol for the Hugging Face lookup, a memory figure, and a free-disk
figure. No test touches the network, and no acceptance criterion depends
on the machine it runs on.

It reports:

1. **Each model reference is well formed** — `owner/name`, no empty
   part, no whitespace. Malformed is an `.error` naming the slot.
2. **Each one resolves.** Through the injected resolver. Not found is an
   `.error` naming the slot and the id, with a fix that names
   `acp-agent config edit`. A network failure is a `.warning`, not an
   `.error`: an offline machine with a warm cache still works.
3. **Cache state.** Is it already on disk? This tells a person whether
   the next run downloads.
4. **The trio fits the machine's memory.** Compare against the injected
   figure. Under the floor is an `.error` naming both numbers and the
   smaller profile to choose.
5. **The free disk covers what must still be downloaded.**
6. **MTP.** A slot whose id holds `-MTP-` is a `.warning`: Router calls
   the plain generate path and never reads the MTP head, so the download
   is larger and the speed is the same. See §7.1.

**Name the resolver timeout in seconds in the code.** The criterion
below asserts against that named value.

- [ ] The shape check
- [ ] The resolve check, over an injected resolver, with a named timeout
- [ ] The cache-state row
- [ ] The memory-fit and free-disk rows, over injected figures
- [ ] The MTP warning row
- [ ] Register it in the doctor component list

### Acceptance Criteria

- [ ] A malformed id gives an `.error` naming the slot.
- [ ] An injected not-found gives an `.error`; an injected network
      failure gives a `.warning`.
- [ ] An injected memory figure below the profile's need gives an
      `.error` stating both figures.
- [ ] A slot naming an MTP model gives exactly one `.warning`; the
      shipped defaults give none.
- [ ] With an all-found resolver, a generous memory figure and a
      generous disk figure, every row is `.ok` or a cache-state note.
      **This is the fixture, not the real machine.**
- [ ] A resolver that never answers gives a `.warning`, and the elapsed
      time is under the named timeout.
- [ ] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

- [ ] `ProfileDoctorTests`: well-formed and malformed ids, with no
      network.
- [ ] The resolver cases: found, not found, network failure, timeout —
      all through the injected resolver.
- [ ] The memory-fit case, with an injected small figure, asserting the
      `.error` message names both numbers.
- [ ] The MTP case: a configuration whose `flash` names
      `mlx-community/Qwen3.5-9B-MTP-4bit` gives one `.warning`; the
      shipped defaults give none.
- [ ] The timeout test asserts the elapsed time is under the named
      bound, and that the check returns rather than hanging.
- [ ] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.