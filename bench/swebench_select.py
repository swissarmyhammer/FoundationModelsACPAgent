"""
swebench_select.py -- which instances of the split a run does.

`swebench_run.py` chose with `all_instances[:LIMIT]`. The dataset is in
alphabetical order, so `--limit N` always gave the same first N instances, and
they start with astropy.

The run of 2026-09-11 did 16 instances that way, and this machine can build
none of the 16:

| Instances | The Python the spec wants | Needs apt |
|---|---|---|
| 4 astropy | 3.9 | yes |
| 2 astropy | 3.6 | no |
| 10 django | 3.6 | no |

So a first run of the harness got the worst instances of the split, it made no
patch, and the numbers said nothing about the agent.

This module answers two questions of the choice.

WHICH INSTANCES CAN RUN

`swebench_venv.py` holds the rule, and this module does not write it a second
time. `unsupported_reason` reads the spec of an instance and gives the reason
this machine cannot build it, or None. Of the 300 instances of the Lite split,
77 want a Python that `uv` does not build for arm64, 44 have a `pre_install`
that is written for linux, the two groups do not intersect, and 179 build here.

The run leaves the other 121 out BEFORE the agent starts. Each reason gets a
count in the log, so a person reads why the run is smaller than the split.

WHICH INSTANCES A SHORT RUN DOES

A sample of the first N instances is a sample of astropy. So `sampled_instances`
takes a random sample, and it gives each repository the places its size earns:
a repository of 114 instances of 300 gets 38 places of each 100. The seed is an
argument, and the run writes it in the log, so the same sample can be done
again.

`repository_quotas` shares the places with the method of the largest remainder:
each repository gets the whole part of its share, and the places that are left
go to the largest remainders. The count of the places is thus the count the
person asked for, and no repository of the split is lost to rounding.

This module has no PEP 723 block, for the reason `swebench_common.py` gives:
`uv run --script` reads the block of the script it starts, and not the block of
a module that the script imports. It needs the standard library and
`swebench_venv.py`, and the table of specs comes from the `swebench` package
that `swebench_run.py` pins.
"""
import random
from dataclasses import dataclass

from swebench_venv import instance_spec, unsupported_reason

# The names of the three fields of a dataset row that this module reads. A row
# holds the problem statement and the tests of the instance as well, and the
# choice reads none of them.
INSTANCE_FIELD = "instance_id"
REPOSITORY_FIELD = "repo"
VERSION_FIELD = "version"
# The seed of the sample when a person names none. It is a constant, so two
# runs of `--sample 10` do the same ten instances and their numbers compare.
# `--seed S` gives another sample, and the run writes the seed in the log.
DEFAULT_SEED = 0
# Where the position of an instance stands in a row of the sample. The sample
# keeps the position of each instance, so it can give the instances back in
# the order of the split.
POSITION = 0
INSTANCE = 1


@dataclass(frozen=True)
class LeftOut:
    """One instance that the run does not do, and why.

    - instance_id: the instance.
    - reason: why this machine cannot build its environment.
    """

    instance_id: str
    reason: str


@dataclass
class Selection:
    """The instances of a run, and the instances it left out.

    - instances: the rows the run does, in the order of the split.
    - left_out: one `LeftOut` for each instance the choice removed.

    This record is not frozen, and `LeftOut` above is. A frozen record with
    `__eq__` also gets a hash, and a hash must read every field and must stay
    the same for the life of the record. The two fields here are lists, and
    the rows in `instances` are dictionaries of the dataset, so no hash of
    them can stand: a caller who puts a `Selection` in a set gets a
    TypeError, although the type told the caller it could. Without `frozen`,
    Python sets `__hash__` to None, the type gives the caller the true
    answer, and `==` still compares the two lists. `LeftOut` holds two
    strings, so it stays frozen and it keeps its hash.
    """

    instances: list
    left_out: list


def instance_reason(instance, *, oldest_python=None, specs=None):
    """Why this machine cannot build one instance, or None when it can.

    - instance: one row of the dataset.
    - oldest_python: the version to try for the old Python group, or None.
    - specs: the table of specs, or None for the published one.

    `swebench_venv.py` owns the rule, and this reads it. A repository or a
    version that the table does not hold gives None, and the instance thus
    gets its chance: the choice removes the instances it KNOWS cannot build,
    and the environment step of the run records the rest.
    """
    try:
        spec = instance_spec(
            instance[REPOSITORY_FIELD], instance[VERSION_FIELD], specs
        )
    except KeyError:
        return None
    return unsupported_reason(spec, oldest_python)


def feasible_instances(instances, *, oldest_python=None, specs=None):
    """The instances this machine can build, and the ones it cannot.

    - instances: the rows of the split, in its own order.
    - oldest_python: the version to try for the old Python group, or None.
    - specs: the table of specs, or None for the published one.

    Returns a `Selection`. The instances that are kept stay in the order of
    the split.
    """
    kept = []
    left_out = []
    for instance in instances:
        reason = instance_reason(
            instance, oldest_python=oldest_python, specs=specs
        )
        if reason is None:
            kept.append(instance)
        else:
            left_out.append(LeftOut(instance[INSTANCE_FIELD], reason))
    return Selection(kept, left_out)


def reason_counts(left_out):
    """How many instances each reason cost, in the order the reasons came.

    - left_out: the `LeftOut` rows of a selection.

    One line for each of 121 instances is not a report a person can read, and
    the reasons are few. So the log of a run gives one line for each reason,
    with the count of its instances.
    """
    counts = {}
    for row in left_out:
        counts[row.reason] = counts.get(row.reason, 0) + 1
    return counts


def repository_quotas(sizes, count):
    """How many places of a sample each repository gets.

    - sizes: the count of instances of each repository.
    - count: how many instances the sample holds.

    A repository of 60 instances of 100 earns 6 places of 10, and the ratio of
    the sample is thus the ratio of the split.

    A share is seldom a whole number, so this uses the method of the largest
    remainder: each repository gets the whole part of its share, and the places
    that are left go to the largest remainders. The count of the places is the
    count the person asked for, and a small repository is not lost to rounding.
    The name of the repository breaks a tie, so the answer is the same on each
    run.

    A sample of more instances than the split holds gives each repository its
    whole size.
    """
    total = sum(sizes.values())
    if total <= count:
        return dict(sizes)
    quotas = {}
    remainders = {}
    for repo, size in sizes.items():
        places = size * count
        quotas[repo] = places // total
        remainders[repo] = places % total
    left = count - sum(quotas.values())
    largest = sorted(sizes, key=lambda repo: (-remainders[repo], repo))
    for repo in largest[:left]:
        quotas[repo] += 1
    return quotas


def sampled_instances(instances, count, seed):
    """A random sample of the instances, in the ratio of the repositories.

    - instances: the rows to choose from, in the order of the split.
    - count: how many instances the sample holds, or None for all of them.
    - seed: the seed of the choice.

    The sample is in the order of the split, because the run does the
    instances in that order and a reader of the log follows it.

    The seed is the whole state of the choice, so the same seed gives the same
    instances on each machine and on each day. The run writes it in the log.
    """
    rows = list(instances)
    if count is None or count >= len(rows):
        return rows
    groups = {}
    for position, instance in enumerate(rows):
        groups.setdefault(instance[REPOSITORY_FIELD], []).append(
            (position, instance)
        )
    sizes = {repo: len(group) for repo, group in groups.items()}
    quotas = repository_quotas(sizes, count)
    chooser = random.Random(seed)
    chosen = []
    # The repositories go in a fixed order, so the seed alone decides which
    # instances the sample holds.
    for repo in sorted(groups):
        chosen.extend(chooser.sample(groups[repo], quotas[repo]))
    chosen.sort(key=lambda row: row[POSITION])
    return [row[INSTANCE] for row in chosen]


def choose_instances(
    instances,
    *,
    keep_feasible=True,
    sample=None,
    seed=DEFAULT_SEED,
    oldest_python=None,
    specs=None,
):
    """The instances of a run, in one call.

    - instances: the rows of the split, in its own order.
    - keep_feasible: whether to leave out the instances that cannot build.
      The default is the default of a run, and `--all` gives False.
    - sample: how many instances to choose at random, or None for all of them.
    - seed: the seed of that sample.
    - oldest_python: the version to try for the old Python group, or None.
    - specs: the table of specs, or None for the published one.

    Returns a `Selection`. The filter runs BEFORE the sample, so a sample of
    ten instances is ten instances the machine can run. With
    `keep_feasible=False` nothing is left out, and the environment step of the
    run then records each instance that does not build.
    """
    if keep_feasible:
        selection = feasible_instances(
            instances, oldest_python=oldest_python, specs=specs
        )
    else:
        selection = Selection(list(instances), [])
    return Selection(
        sampled_instances(selection.instances, sample, seed), selection.left_out
    )
