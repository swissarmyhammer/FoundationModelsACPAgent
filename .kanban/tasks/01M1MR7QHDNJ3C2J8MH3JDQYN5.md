---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m230b3zmn0jb124xbw215qk9
  text: |-
    ### The upstream card is made

    `FoundationModelsACPClient` card **`^9vkmz1f`** — "N5: the doctor subcommand for a foreign agent". It is in `todo` and carries the full specification of this card, written from the ACPClient view.

    The card also carries two facts this session measured, so the upstream work does not have to find them again:
    - The Extras `Doctorable` module is on Extras `main` at `55d6b04`, and a `main` branch dependency stays pinned by revision until `swift package update` runs.
    - Do NOT model "never answers" with a never-resumed `withCheckedContinuation`. That prints `SWIFT TASK CONTINUATION MISUSE` and leaves a suspended task. A stub that waits and answers late is cancellable and leaves nothing behind.

    This card stays open until that one is done and merged to ACPClient `main`.
  timestamp: 2026-09-09T11:55:06.612486+00:00
depends_on:
- 01M1MNXE777J4XA3NJTP483A8W
- 01M1MR74AAC3HM74F26P39Z3BC
position_column: todo
position_ordinal: '9680'
title: 'acp-client N5: the doctor subcommand for a foreign agent'
---
### What

Upstream work in `../FoundationModelsACPClient`, milestone **N5** of its
`cli-plan.md` §10. This is the only client milestone that needs the
Extras `Doctorable` module, so it is the only one blocked by it.

`acp-client doctor -- <agent-command>` answers one question about a
foreign agent: is it usable? One `Doctorable` conformance over an agent
command:

| Check | Catches |
|---|---|
| The command exists on `PATH`, or at the given path, and it is executable | A typing mistake, or a binary that was not built |
| The process starts, and it does not exit at once | A missing runtime, or a crash on start |
| It writes valid ndJSON, and nothing else, to stdout | An agent that prints a banner to stdout |
| `initialize` answers inside the time limit | An agent that hangs |
| The protocol version is one we support | A v1 agent, or a newer draft |
| The advertised capabilities are readable | A malformed `initialize` result |
| The process ends when its stdin closes, and it leaves no child | A leaked agent |

The third row is worth the command on its own: "the agent MUST NOT write
non-ACP content to stdout" is a protocol MUST, and an agent that breaks
it fails in a way that looks like a parsing bug in **our** client.

**Rendering.** The human table goes to stderr through the client's
`TerminalRenderer` when stderr is a terminal, and through the Extras
plain-text renderer otherwise. `--json` writes the report to stdout.
Exit 0, 1 or 5.

Every check carries a timeout. Name it in seconds. `doctor` must never
hang.

- [ ] The `Doctorable` conformance, with the seven checks
- [ ] The terminal and the plain rendering paths
- [ ] `--json` to stdout, and the three exit codes
- [ ] Refresh and commit `Package.resolved` so the new Extras
      `Doctorable` surface is visible: a `main` branch dependency stays
      pinned by revision until `swift package update` runs

### Acceptance Criteria

- [ ] A stub that writes a banner to stdout gives that row an `.error`.
- [ ] A stub that never answers `initialize` gives a timeout `.warning`
      inside the named limit, and the command does not hang.
- [ ] A command that does not exist gives an `.error` naming it.
- [ ] Exit 0 for all `.ok`, 1 for any `.error`, 5 for warnings only.
- [ ] `--json` decodes to the same checks the table shows.
- [ ] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

Two new stub agents are necessary, and both are a few lines: one that
writes a banner to stdout, and one that never answers.

- [ ] The banner stub gives an `.error` on the ndJSON row.
- [ ] The silent stub gives a timeout `.warning`, and the test asserts
      the elapsed time is under the limit.
- [ ] A nonexistent command gives an `.error`.
- [ ] The three exit codes, one test each.
- [ ] `--json` decodes and matches.
- [ ] With a non-terminal destination the output holds no ANSI escape.
- [ ] `swift test` in `../FoundationModelsACPClient` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.