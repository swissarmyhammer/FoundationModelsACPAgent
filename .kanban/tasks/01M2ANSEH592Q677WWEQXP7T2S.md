---
assignees:
- claude-code
depends_on:
- 01M2ANS2RQV9D4E4MPXM3FDCVH
position_column: todo
position_ordinal: '8680'
title: 'bench: choose the instances that can run, and choose them fairly'
---
## The problem

`bench/swebench_run.py` selects with `instances = all_instances[:LIMIT]`. The
dataset is in alphabetical order, so `--limit N` always gives the same first N,
and they start with `astropy`.

The run of 2026-09-11 did 16 instances. All 16 are in the group that cannot
run on this machine as the harness is now:

| Instances | Python the spec wants | Needs apt |
|---|---|---|
| 4 astropy | 3.9 | yes |
| 2 astropy | 3.6 | no |
| 10 django | 3.6 | no |

Twelve of the sixteen want Python 3.6, and uv has no 3.6 or 3.7 build for
arm64. Four need `apt-get`, which is linux only. A first run of the harness
thus gets the worst instances of the split, and the numbers say nothing about
the agent.

## The work

1. Add `--feasible`, which keeps only the instances this machine can run: the
   spec has no `pre_install`, and uv has the Python of the spec. Make it the
   default, and add `--all` to turn it off.
2. Add `--sample N` with `--seed S`, which takes a random sample of N
   instances. Keep the repositories in the same ratio as the split. Write the
   seed in the log, so a run can be done again.
3. Write the count and the reason in the log when an instance is left out.
4. Give the README the numbers of the Lite split:

| Condition | Instances |
|---|---|
| Python 3.6, and uv has no build | 77 |
| `pre_install` with apt, linux only | 44 |
| **Can run on this mac** | **179** |

The two groups do not intersect.

## When it is complete

- The default run selects only the instances that can run.
- `--sample 10 --seed 1` gives the same ten instances each time.
- A short run is a mix of repositories, and not astropy alone.
- The README says which instances do not run, and why.

Related: [[bench-prepare-the-instance-environment-in-the-driver]] #bench