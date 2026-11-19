---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rgtz715wzhqa2axbztcdwm
  text: |-
    ### review — clean
    - evidence: review sha d5693f2~1..d5693f2; findings 0, confirmed 0, refuted 0, attempted 7, failed 0. No validator matched README.md, and the engine did not review it.
    - next: none. The task is in done.
  timestamp: 2026-11-18T23:45:55.425612+00:00
depends_on:
- 01M7QPEYYX1W0B4MDQ7T2T3ZWW
position_column: done
position_ordinal: ffffff8680
title: 'ACPA-23 (D203): `config init` does not write `profile: large`, so the default by fit applies'
---
Found during ^t2t3zww (2026-11-18). Decision D203 in `TestudoApp/features/decisions.md`: with no `profile` set, the agent uses the largest profile that fits, and `small` when no fit can be read.

## Dependency

^t2t3zww (the default by fit).

## Current behavior

`acp-agent config init` writes a `config.yaml` with `profile: large`. `Config.makeLoader` (used by `init`, `edit` and `path`) uses `large` explicitly, to keep the written file the same on every Mac. Thus each user who runs `config init` pins `large` and turns off the default by fit. On a Mac with less than 48 GB, `large` does not fit.

## Change

1. The file that `config init` writes has no `profile` key (or a comment that names the profiles and the default by fit), so the default by fit applies.
2. The written file is still the same on every Mac.
3. `config edit` and `config path` do not change behavior.

## Tests

- `config init` writes no `profile` key.
- A load of that file selects the profile of the fit source (stub).
- The written file is the same with two different fit stubs. #d203 #profiles #acpa-23