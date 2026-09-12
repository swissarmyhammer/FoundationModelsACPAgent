---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2b3qt2fbk2ee3c1ty9had81
  text: |-
    Picked up the card. Research of the code before the first edit:

    - `bench/swebench_venv.py` holds the rule already: `unsupported_reason(spec, oldest_python=None)` gives the reason, or None when the machine can build the instance. `instance_spec(repo, version, specs=None)` reads `MAP_REPO_VERSION_TO_SPECS`. The new module reuses both. It writes no second copy of the rule.
    - `bench/swebench_run.py` chooses with `instances = all_instances[:LIMIT] if LIMIT else all_instances`, after the `-i` list. That is the line to replace.
    - The pattern of the six sibling tasks: one small module, one `bench/test_*.py` beside it, `swebench_common.log(message, **fields)` with a constant message, and the stand-in for `subprocess.run` of `bench/test_fixtures.py`. The new module starts no process, so it needs no stand-in. It gets its tables from the test, as `bench/test_swebench_venv.py` does.
    - `.github/workflows/bench.yml` finds every `bench/test_*.py`, so a new test file needs no step. Its comment names each module, so the comment gets the new name.

    The plan: a new module `bench/swebench_select.py` with `feasible_instances`, `reason_counts`, `repository_quotas`, `sampled_instances` and `choose_instances`, and `bench/test_swebench_select.py` beside it. Then `--feasible` (the default), `--all`, `--sample N` and `--seed S` in `swebench_run.py`, and the numbers of the Lite split in `bench/README.md`.
  timestamp: 2026-09-12T15:28:23.631449+00:00
- actor: claude-code
  id: 01m2b44g72cj1j7g9kxmjfnsya
  text: |-
    The work landed. What it is:

    - `bench/swebench_select.py` is new. It holds `instance_reason`, `feasible_instances`, `reason_counts`, `repository_quotas`, `sampled_instances` and `choose_instances`, with the `Selection` and `LeftOut` records. It reads the rule from `swebench_venv.unsupported_reason`, so there is one copy of the rule. A repository or a version that the published table does not hold gives None, and the instance keeps its chance: the choice removes only the instances it KNOWS cannot build, and the environment step records the rest.
    - `bench/test_swebench_select.py` is new, with 20 tests in four classes. Each test gives the module a table of specs of its own, so it reads no dataset and no published table. The tests ran RED before each part of the module.
    - `bench/swebench_run.py` now calls `choose_instances` after the `-i` list. `--feasible` is the default, `--all` turns it off, `--sample N` and `--seed S` take a fair sample, and `--limit N` takes the first N of the answer. A log line for each reason gives the count, and a `left out` row joins the table of the summary.
    - `bench/README.md` has a new section "Which instances a run does" with the table 77 / 44 / 179, the log line, and "A fair sample". The old table under the environment section is gone, so the numbers stand in one place.
    - `.github/workflows/bench.yml` names the new module in its comment. The step finds `bench/test_swebench_select.py` with no change.

    The sample of the largest remainder: each repository gets the whole part of its share, and the places that are left go to the largest remainders. The count of a sample is thus the count the person asked for, and a small repository is not lost to rounding. The repositories go in a fixed order, so the seed alone decides the choice.

    Measured against the real Lite split with `uv run` (the dataset and `swebench` 4.0.5, not a unit test):

        split 300 / kept 179 / left out 121
        44 the spec has a `pre_install`, and those commands are written for linux
        77 the spec wants Python 3.6, and `uv` has no build of it for this machine
        --sample 10 --seed 1 gives the same ten in two calls, and they are
        django (3), psf (1), pylint-dev (1), pytest-dev (1), sympy (4)

    So each condition of the card is met: the numbers are 77, 44 and 179; the default run selects the instances that can run; the same seed gives the same instances; and a short run is a mix of repositories, and not astropy alone.

    One decision to know about: the choice reads `-i` too, so an id of the 121 is left out and the run says why. `--all` does that instance. The README says so under "One problem only".
  timestamp: 2026-09-12T15:35:19.522497+00:00
- actor: claude-code
  id: 01m2b44m100m282qz0xp67wxzq
  text: |-
    ### implement — changed
    - evidence: 5 files — bench/swebench_select.py (new), bench/test_swebench_select.py (new, 20 tests), bench/swebench_run.py (choose_instances, --feasible/--all/--sample/--seed, the log lines, the `left out` row), bench/README.md (the section "Which instances a run does"), .github/workflows/bench.yml (the comment). `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'`: 178 tests, 0 failures.
    - next: /review
  timestamp: 2026-09-12T15:35:23.424839+00:00
- actor: claude-code
  id: 01m2b49ajc7as13h5ne3pzsr0g
  text: |-
    ### commit — changed
    - evidence: 40139a4 feat(bench): choose the instances that can run, and choose them fairly — 9 files
    - next: none, local commit only, not pushed
  timestamp: 2026-09-12T15:37:57.580259+00:00
- actor: claude-code
  id: 01m2b4jdzkrfzd9fqnmbj6vhe6
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`, 1 finding, 1 confirmed, 0 refuted — bench/swebench_select.py:86
    - next: correct the finding, then run /review again on the same task

    The `-i` decision is correct and it is documented. The choice reads the `-i`
    list with the same rule as the whole run, it writes the reason in the log, and
    `--all` does the instance. `bench/README.md` says so under "One problem only"
    and under "Which instances a run does".
  timestamp: 2026-09-12T15:42:55.987222+00:00
- actor: claude-code
  id: 01m2b4jzvxy0683atv59j30dm5
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files: bench/swebench_select.py (new), bench/test_swebench_select.py (new, 20 tests), bench/swebench_run.py, bench/README.md, .github/workflows/bench.yml
    - test: green — 178 Python tests passed, 561 Swift tests passed, 0 failed, 0 skipped. ruff check bench clean. `--help` shows --feasible, --all, --sample and --seed.
    - commit: 1b60ec1 — 9 files, local only, not pushed
    - review: findings — 1 confirmed, 0 refuted, scope HEAD~1..HEAD
    - open: bench/swebench_select.py:86 — python/hashing-and-equality. `Selection` is a frozen dataclass, so Python makes `__hash__`. Its fields `instances` and `left_out` are lists, which no hash can read, so a hash of a `Selection` raises TypeError.
    - the review confirms the choice reads `-i` too, and that the README says so two times. The acceptance conditions of the card are met: the numbers 77, 44 and 179 are in the README, the default run takes the instances that can run, `--sample 10 --seed 1` repeats, and a short run mixes the repositories.
    - next: iteration 2 — repair that finding, then test, commit and review again.
  timestamp: 2026-09-12T15:43:14.301710+00:00
- actor: claude-code
  id: 01m2b4r8p682vpyyytc3pcm4j9
  text: |-
    Iteration 2. The finding `bench/swebench_select.py:86` `python/hashing-and-equality` is repaired.

    Which of the three repairs, and why:

    1. `@dataclass(frozen=True, hash=False)` is not Python. `dataclass()` has no `hash` argument: it has `eq`, `frozen` and `unsafe_hash`. The call gives `TypeError: dataclass() got an unexpected keyword argument 'hash'` on Python 3.14. Measured, not remembered.
    2. Tuple fields do not make a `Selection` hashable. The `instances` field holds rows of the dataset, and a row is a dictionary. A tuple of dictionaries has no hash, so the record would raise the same TypeError. The rule says as well: "Never hash mutable attributes. A hash must be stable over the object's lifetime."
    3. So the record loses `frozen`. Python then sets `__hash__` to None, the type tells a caller the truth, and `==` still compares the two lists. This is the repair.

    `LeftOut` in the same file holds two strings, so it is truly immutable and its hash stands. It keeps `frozen=True`. The docstring of `Selection` now says why the two records differ, so the next reader does not make them the same again.

    The rest of the file and the sibling modules were read for the same shape: the only other frozen records of `bench/` are `EnvironmentReport` of `swebench_venv.py` and `TurnReport` of `swebench_acp.py`. Each field of those two is a string, a float, an int or a bool, so both are correct as they stand, and neither was touched.

    The proof is `RecordTests.test_a_selection_does_not_say_a_caller_can_hash_it` of `bench/test_swebench_select.py`. It asserts `assertNotIsInstance(selection, Hashable)`. Against the code before the repair it FAILED: "Selection(...) is an instance of <class 'collections.abc.Hashable'>". After the repair it passes.

    `swebench_run.py` is the only caller of the module. It reads `.instances` and `.left_out`, and it hashes nothing, so the repair changes no behavior of a run.
  timestamp: 2026-09-12T15:46:07.174445+00:00
- actor: claude-code
  id: 01m2b4rm2480nk3ttkbqp7yx16
  text: |-
    ### implement — changed
    - evidence: 2 files — bench/swebench_select.py (`Selection` is `@dataclass` now, not `@dataclass(frozen=True)`, and its docstring says why it differs from `LeftOut`), bench/test_swebench_select.py (the new class `RecordTests` with `test_a_selection_does_not_say_a_caller_can_hash_it`, and the import of `collections.abc.Hashable`). The test FAILED against the code before the repair. `python3 -m unittest discover --start-directory bench --pattern 'test_*.py'`: 179 tests, 0 failures. `ruff check bench`: all checks passed. The one finding of the card is `- [x]`.
    - next: /review
  timestamp: 2026-09-12T15:46:18.820414+00:00
depends_on:
- 01M2ANS2RQV9D4E4MPXM3FDCVH
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-09-12 10:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `bench/README.md` — no validator matches this file

- [x] `bench/swebench_select.py:86` `python/hashing-and-equality` — `Selection` is declared frozen (immutable) with `@dataclass(frozen=True)`, which causes Python to auto-generate both `__eq__()` and `__hash__()`. However, the fields `instances: list` and `left_out: list` are unhashable. Any attempt to hash a Selection instance will raise `TypeError` at runtime, violating the contract that immutable objects with `__eq__` must be properly hashable. Either: (1) use `@dataclass(frozen=True, hash=False)` to explicitly disable hash generation, or (2) replace `list` fields with `tuple` fields to make Selection properly hashable, or (3) remove `frozen=True` if mutability is acceptable.
