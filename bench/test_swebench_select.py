#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_select.py -- the proof that a run chooses the instances it can
run, and that it chooses them fairly.

`swebench_run.py` chose with `all_instances[:LIMIT]`. The dataset is in
alphabetical order, so `--limit N` always gave the same first N instances, and
they start with astropy.

The run of 2026-09-11 did 16 instances that way. This machine can build none of
them: 12 want Python 3.6, which `uv` does not build for arm64, and 4 need
`apt-get`. A first run of the harness thus got the worst instances of the
split, and the numbers said nothing about the agent.

`swebench_select.py` chooses now. It leaves out each instance that this machine
cannot build, and it can take a random sample that holds each repository in the
ratio of the split.

No test here reads the dataset, and no test here reads the published table of
the `swebench` package. Each test gives the module a table of its own, as
`test_swebench_venv.py` does, so the answer is the same on each machine.

This test needs the standard library only, so both commands run it:

    uv run bench/test_swebench_select.py
    python3 bench/test_swebench_select.py
"""
import unittest
from collections.abc import Hashable

from swebench_select import (
    choose_instances,
    feasible_instances,
    reason_counts,
    repository_quotas,
    sampled_instances,
)

# The names below are the names of a test, and not the names of the split. A
# test that reads the dataset gives a different answer on each day.
A_REPOSITORY = "astropy/astropy"
ANOTHER_REPOSITORY = "django/django"
A_THIRD_REPOSITORY = "sympy/sympy"
# One version for each condition of the table of specs below. A version is a
# key of that table, so a test says which spec an instance gets by the version
# it gives that instance.
A_VERSION_THAT_BUILDS = "5.1"
A_VERSION_WITH_AN_OLD_PYTHON = "3.0"
A_VERSION_WITH_A_PRE_INSTALL = "4.0"
A_VERSION_THE_TABLE_DOES_NOT_HOLD = "9.9"
# The Python that `uv` builds on this machine, and the one it does not. The
# spec of 77 instances of the Lite split names 3.6, and `uv` has no build of
# 3.6 and no build of 3.7 for macOS arm64.
A_PYTHON = "3.9"
AN_OLD_PYTHON = "3.6"
A_PYTHON_TO_USE_IN_ITS_PLACE = "3.8"
# A table of specs with the shape that `MAP_REPO_VERSION_TO_SPECS` gives: a
# repository, and then a version. Each spec is short, because a test reads the
# condition and not the list of packages.
SPECS = {
    A_REPOSITORY: {
        A_VERSION_THAT_BUILDS: {"python": A_PYTHON},
        A_VERSION_WITH_AN_OLD_PYTHON: {"python": AN_OLD_PYTHON},
        A_VERSION_WITH_A_PRE_INSTALL: {
            "python": A_PYTHON,
            "pre_install": ["apt-get install -y libxml2"],
        },
    },
    ANOTHER_REPOSITORY: {
        A_VERSION_THAT_BUILDS: {"python": A_PYTHON},
        A_VERSION_WITH_AN_OLD_PYTHON: {"python": AN_OLD_PYTHON},
    },
    A_THIRD_REPOSITORY: {
        A_VERSION_THAT_BUILDS: {"python": A_PYTHON},
    },
}
# The shape of a split of a test: three repositories, in alphabetical order,
# and the first one holds the most instances. That is the shape of the Lite
# split, and it is the shape that made `all_instances[:16]` an astropy run.
A_SPLIT = ((A_REPOSITORY, 60), (ANOTHER_REPOSITORY, 30), (A_THIRD_REPOSITORY, 10))
# How many instances a short run does. Ten of the hundred above.
A_SHORT_RUN = 10
# Two seeds. The same seed must give the same instances, and another seed must
# give other instances.
A_SEED = 1
ANOTHER_SEED = 2


def an_instance(repo, version, instance_id):
    """One row of the dataset, with the three names this module reads.

    - repo: the name of the repository, for example `django/django`.
    - version: the version of the instance.
    - instance_id: the name of the instance.

    A row of the dataset holds the problem statement and the tests as well.
    This module reads none of them, so a row of a test holds three names.
    """
    return {"instance_id": instance_id, "repo": repo, "version": version}


def instance_ids(instances):
    """The name of each instance, in order.

    - instances: the rows to read.

    An assertion on the names says which instances the module chose. An
    assertion on the rows says the same thing, and it is not readable.
    """
    return [instance["instance_id"] for instance in instances]


def a_split(sizes, version=A_VERSION_THAT_BUILDS):
    """The rows of a split, with a count of instances for each repository.

    - sizes: pairs of a repository and the count of its instances.
    - version: the version each instance gets, which chooses its spec.

    The rows come in the order of the argument, as the dataset comes in
    alphabetical order. The name of each instance holds its repository, so a
    failed assertion says which repository was chosen too many times.
    """
    instances = []
    for repo, count in sizes:
        for number in range(count):
            instances.append(an_instance(repo, version, f"{repo}-{number}"))
    return instances


def repositories_of(instances):
    """The count of instances of each repository.

    - instances: the rows to read.

    The ratio of the repositories is what makes a short run a run of the
    split, and not a run of astropy.
    """
    counts = {}
    for instance in instances:
        counts[instance["repo"]] = counts.get(instance["repo"], 0) + 1
    return counts


class RecordTests(unittest.TestCase):
    """The two records of the module, and what a caller can do with them."""

    def test_a_selection_does_not_say_a_caller_can_hash_it(self):
        """A `Selection` holds two lists, so it has no hash.

        A caller asks a type whether it can hash a value, and it then puts the
        value in a set or in a key. A record that answers yes, and then stops
        the caller with a TypeError, gives a wrong answer to that question.
        The lists hold rows of the dataset, and a person can change a list
        after the record is made, so no hash of a `Selection` could stay the
        same for the life of the record.
        """
        instances = [an_instance(A_REPOSITORY, A_VERSION_THAT_BUILDS, "a-1")]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertNotIsInstance(selection, Hashable)


class FeasibleTests(unittest.TestCase):
    """The instances that this machine can build, and the ones it cannot."""

    def test_an_instance_that_builds_is_kept(self):
        """The whole point: an instance this machine can build must run.

        A filter that left out a good instance would make the split smaller
        for no reason, and the score would then be of another population.
        """
        instances = [an_instance(A_REPOSITORY, A_VERSION_THAT_BUILDS, "a-1")]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(instance_ids(selection.instances), ["a-1"])
        self.assertEqual(selection.left_out, [])

    def test_a_spec_with_a_pre_install_is_left_out(self):
        """A `pre_install` is written for linux, so the build cannot run here.

        The agent would get an instance it cannot test, and the hour of that
        instance would be lost.
        """
        instances = [an_instance(A_REPOSITORY, A_VERSION_WITH_A_PRE_INSTALL, "a-2")]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(selection.instances, [])
        self.assertEqual(len(selection.left_out), 1)
        self.assertEqual(selection.left_out[0].instance_id, "a-2")
        self.assertIn("pre_install", selection.left_out[0].reason)

    def test_an_instance_of_the_old_python_group_is_left_out(self):
        """`uv` has no build of Python 3.6 for this machine.

        The reason must name the version the spec wants, because that is the
        fact a person needs to choose a version with --oldest-python.
        """
        instances = [an_instance(A_REPOSITORY, A_VERSION_WITH_AN_OLD_PYTHON, "a-3")]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(selection.instances, [])
        self.assertIn(AN_OLD_PYTHON, selection.left_out[0].reason)

    def test_an_older_python_of_the_person_brings_an_instance_back(self):
        """--oldest-python gives the old Python group a version to try.

        The filter must read that choice. A filter that did not read it would
        leave 77 instances out although the person asked for them.
        """
        instances = [an_instance(A_REPOSITORY, A_VERSION_WITH_AN_OLD_PYTHON, "a-3")]

        selection = feasible_instances(
            instances, oldest_python=A_PYTHON_TO_USE_IN_ITS_PLACE, specs=SPECS
        )

        self.assertEqual(instance_ids(selection.instances), ["a-3"])

    def test_an_instance_the_table_does_not_hold_is_kept(self):
        """A version that the published table does not name is not a refusal.

        The filter leaves out the instances it KNOWS this machine cannot
        build. An instance it cannot judge gets its chance, and the
        environment step of the run then records what happened to it.
        """
        instances = [
            an_instance(A_REPOSITORY, A_VERSION_THE_TABLE_DOES_NOT_HOLD, "a-4")
        ]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(instance_ids(selection.instances), ["a-4"])

    def test_every_instance_is_kept_when_the_filter_is_off(self):
        """--all turns the filter off, and the run then does every instance.

        A person who wants to measure the environment step itself needs the
        instances that fail it.
        """
        instances = [
            an_instance(A_REPOSITORY, A_VERSION_THAT_BUILDS, "a-1"),
            an_instance(A_REPOSITORY, A_VERSION_WITH_A_PRE_INSTALL, "a-2"),
            an_instance(A_REPOSITORY, A_VERSION_WITH_AN_OLD_PYTHON, "a-3"),
        ]

        selection = choose_instances(instances, keep_feasible=False, specs=SPECS)

        self.assertEqual(instance_ids(selection.instances), ["a-1", "a-2", "a-3"])
        self.assertEqual(selection.left_out, [])

    def test_the_instances_that_are_kept_stay_in_the_order_of_the_split(self):
        """The filter removes instances, and it orders nothing.

        A run that continues reads the predictions file for the instances it
        did. An order that moved would make that file hard to read.
        """
        instances = [
            an_instance(A_REPOSITORY, A_VERSION_THAT_BUILDS, "a-1"),
            an_instance(A_REPOSITORY, A_VERSION_WITH_A_PRE_INSTALL, "a-2"),
            an_instance(ANOTHER_REPOSITORY, A_VERSION_THAT_BUILDS, "b-1"),
        ]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(instance_ids(selection.instances), ["a-1", "b-1"])


class ReasonCountTests(unittest.TestCase):
    """The count of the instances that are left out, for each reason."""

    def test_each_reason_gets_the_count_of_its_instances(self):
        """The log line of a run says how many instances each reason cost.

        A run that left 121 instances out must say why, and one line for each
        instance is not a report a person can read.
        """
        instances = [
            an_instance(A_REPOSITORY, A_VERSION_WITH_AN_OLD_PYTHON, "a-3"),
            an_instance(ANOTHER_REPOSITORY, A_VERSION_WITH_AN_OLD_PYTHON, "b-3"),
            an_instance(A_REPOSITORY, A_VERSION_WITH_A_PRE_INSTALL, "a-2"),
        ]

        selection = feasible_instances(instances, specs=SPECS)
        counts = reason_counts(selection.left_out)

        self.assertEqual(sorted(counts.values()), [1, 2])
        self.assertEqual(sum(counts.values()), 3)

    def test_no_instance_that_is_left_out_gives_no_count(self):
        """A run of good instances writes no line about the ones it left out."""
        instances = [an_instance(A_REPOSITORY, A_VERSION_THAT_BUILDS, "a-1")]

        selection = feasible_instances(instances, specs=SPECS)

        self.assertEqual(reason_counts(selection.left_out), {})


class QuotaTests(unittest.TestCase):
    """How many places of a sample each repository gets."""

    def test_each_repository_gets_the_places_of_its_size(self):
        """A repository of 60 instances of 100 gets 6 places of 10.

        The ratio of the sample is the ratio of the split. That is what makes
        the number of a short run a number of the split.
        """
        sizes = {A_REPOSITORY: 60, ANOTHER_REPOSITORY: 30, A_THIRD_REPOSITORY: 10}

        quotas = repository_quotas(sizes, A_SHORT_RUN)

        self.assertEqual(
            quotas,
            {A_REPOSITORY: 6, ANOTHER_REPOSITORY: 3, A_THIRD_REPOSITORY: 1},
        )

    def test_the_places_that_rounding_leaves_go_to_the_largest_remainders(self):
        """Every place of the sample is given, and no repository is lost.

        5, 3 and 2 instances of 10 earn 1.5, 0.9 and 0.6 places of 3. The whole
        parts are 1, 0 and 0, so two places are left. They go to the two
        largest remainders, and the sample is 3 instances and not 1.
        """
        sizes = {A_REPOSITORY: 5, ANOTHER_REPOSITORY: 3, A_THIRD_REPOSITORY: 2}

        quotas = repository_quotas(sizes, 3)

        self.assertEqual(
            quotas,
            {A_REPOSITORY: 1, ANOTHER_REPOSITORY: 1, A_THIRD_REPOSITORY: 1},
        )

    def test_a_sample_of_more_than_the_split_gives_each_repository_its_size(self):
        """A person who asks for more instances than there are gets them all."""
        sizes = {A_REPOSITORY: 2, ANOTHER_REPOSITORY: 1}

        quotas = repository_quotas(sizes, A_SHORT_RUN)

        self.assertEqual(quotas, sizes)


class SampleTests(unittest.TestCase):
    """The random sample of the instances, in the ratio of the split."""

    def test_the_same_seed_gives_the_same_instances(self):
        """A run must be able to do the same ten instances again.

        Two runs of `--sample 10 --seed 1` compare only if the ten instances
        are the same ten.
        """
        instances = a_split(A_SPLIT)

        first = sampled_instances(instances, A_SHORT_RUN, A_SEED)
        again = sampled_instances(instances, A_SHORT_RUN, A_SEED)

        self.assertEqual(instance_ids(first), instance_ids(again))

    def test_another_seed_gives_other_instances(self):
        """The seed must decide the choice, and not decorate it.

        A sample that gave the same instances for each seed would be the first
        N again, with another name.
        """
        instances = a_split(A_SPLIT)

        first = sampled_instances(instances, A_SHORT_RUN, A_SEED)
        other = sampled_instances(instances, A_SHORT_RUN, ANOTHER_SEED)

        self.assertNotEqual(instance_ids(first), instance_ids(other))

    def test_the_sample_holds_each_repository_in_the_ratio_of_the_split(self):
        """60, 30 and 10 instances of 100 give 6, 3 and 1 of 10."""
        instances = a_split(A_SPLIT)

        sample = sampled_instances(instances, A_SHORT_RUN, A_SEED)

        self.assertEqual(
            repositories_of(sample),
            {A_REPOSITORY: 6, ANOTHER_REPOSITORY: 3, A_THIRD_REPOSITORY: 1},
        )

    def test_the_sample_stays_in_the_order_of_the_split(self):
        """The sample chooses the instances, and it orders nothing.

        The run does the instances in the order of the file, so a reader of
        the log reads them in the order of the split.
        """
        instances = a_split(A_SPLIT)

        sample = sampled_instances(instances, A_SHORT_RUN, A_SEED)

        chosen = set(instance_ids(sample))
        in_the_split = [name for name in instance_ids(instances) if name in chosen]
        self.assertEqual(instance_ids(sample), in_the_split)

    def test_a_sample_of_more_than_the_split_gives_every_instance(self):
        """A person who asks for 10 of 3 instances gets the 3."""
        instances = a_split(((A_REPOSITORY, 2), (ANOTHER_REPOSITORY, 1)))

        sample = sampled_instances(instances, A_SHORT_RUN, A_SEED)

        self.assertEqual(instance_ids(sample), instance_ids(instances))

    def test_no_sample_gives_every_instance(self):
        """A run without --sample does the whole split."""
        instances = a_split(A_SPLIT)

        sample = sampled_instances(instances, None, A_SEED)

        self.assertEqual(instance_ids(sample), instance_ids(instances))


class ChoiceTests(unittest.TestCase):
    """The choice of a run: the filter first, and then the sample."""

    def test_a_short_run_is_a_mix_of_repositories(self):
        """The defect of the card: `--limit 16` gave 16 astropy instances.

        The first 10 rows of the split below are astropy rows. A sample of 10
        must hold each of the three repositories.
        """
        instances = a_split(A_SPLIT)

        selection = choose_instances(
            instances, sample=A_SHORT_RUN, seed=A_SEED, specs=SPECS
        )

        self.assertEqual(len(selection.instances), A_SHORT_RUN)
        self.assertEqual(len(repositories_of(selection.instances)), len(A_SPLIT))

    def test_the_sample_is_of_the_instances_that_can_run(self):
        """The filter runs first, so the sample holds no unsupported instance.

        A sample taken before the filter would give a run of fewer instances
        than the person asked for.
        """
        instances = a_split(
            ((A_REPOSITORY, 20),), version=A_VERSION_WITH_A_PRE_INSTALL
        ) + a_split(((ANOTHER_REPOSITORY, 20),))

        selection = choose_instances(
            instances, sample=A_SHORT_RUN, seed=A_SEED, specs=SPECS
        )

        self.assertEqual(len(selection.instances), A_SHORT_RUN)
        self.assertEqual(
            repositories_of(selection.instances), {ANOTHER_REPOSITORY: A_SHORT_RUN}
        )
        self.assertEqual(len(selection.left_out), 20)


if __name__ == "__main__":
    unittest.main()
