#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""
test_swebench_harness.py -- the proof that the score script calls the harness
correctly, and that it stops on an error that is not a docker failure.

Two rules hold, and these tests hold them:

  1. The call agrees with the pinned harness. The keyword names are the
     parameters of `swebench.harness.run_evaluation.main` in swebench==5.0.2.
     A name that the harness does not know (for example `force_rebuild`)
     makes a TypeError, and then no instance runs.

  2. Only a docker failure goes on to the tally. Any other error, for example
     that TypeError, raises `HarnessCallError`. The score script then stops,
     it does no second try, and it does not say that memory is the cause.

The tests use only the standard library. When swebench is installed, one
more test compares the names with the real signature.
"""
import inspect
import unittest

from swebench_harness import (
    HARNESS_PARAMETERS,
    HarnessCallError,
    call_harness,
    harness_arguments,
    is_docker_failure,
    is_memory_failure,
)

try:
    from swebench.harness.run_evaluation import main as real_harness
except ImportError:
    real_harness = None


def some_arguments():
    """The arguments of one harness pass, with values of a test."""
    return harness_arguments(
        dataset_name="SWE-bench/SWE-bench_Lite",
        split="test",
        instance_ids=("django__django-11099",),
        predictions_path="/tmp/preds.jsonl",
        max_workers=1,
        run_id="score_test",
        timeout=1800,
    )


def a_docker_error(text):
    """An error whose class comes from `docker.errors`, as the library raises."""
    kind = type("APIError", (Exception,), {"__module__": "docker.errors"})
    return kind(text)


def a_harness_image_error(text):
    """The error that the harness raises when it cannot get an image."""
    kind = type("EvaluationError", (Exception,), {"__module__": "swebench.harness.utils"})
    return kind(text)


class HarnessArgumentsTests(unittest.TestCase):
    """Rule 1: the call agrees with the pinned harness."""

    def test_the_keys_are_the_parameters_of_the_harness(self):
        self.assertEqual(tuple(some_arguments()), HARNESS_PARAMETERS)

    def test_no_key_of_the_old_harness_is_sent(self):
        for old in ("force_rebuild", "cache_level", "clean", "namespace"):
            self.assertNotIn(old, some_arguments())

    def test_the_run_is_local_and_writes_new_reports(self):
        arguments = some_arguments()
        self.assertIs(arguments["modal"], False)
        self.assertIs(arguments["rewrite_reports"], False)
        self.assertIsNone(arguments["task_repo"])
        self.assertEqual(arguments["instance_ids"], ["django__django-11099"])
        self.assertEqual(arguments["predictions_path"], "/tmp/preds.jsonl")

    @unittest.skipIf(real_harness is None, "swebench is not installed")
    def test_the_keys_agree_with_the_real_signature(self):
        parameters = inspect.signature(real_harness).parameters
        self.assertEqual(tuple(parameters), HARNESS_PARAMETERS)
        required = {
            name for name, p in parameters.items() if p.default is inspect.Parameter.empty
        }
        self.assertLessEqual(required, set(some_arguments()))
        inspect.signature(real_harness).bind(**some_arguments())


class CallHarnessTests(unittest.TestCase):
    """Rule 2: only a docker failure goes on to the tally."""

    def test_a_pass_with_no_error_returns_none(self):
        calls = []
        self.assertIsNone(call_harness(lambda **kw: calls.append(kw), some_arguments()))
        self.assertEqual(calls, [some_arguments()])

    def test_a_type_error_raises_and_names_the_error(self):
        calls = []

        def a_harness_that_refuses(**kw):
            calls.append(kw)
            raise TypeError("main() got an unexpected keyword argument 'force_rebuild'")

        with self.assertRaises(HarnessCallError) as raised:
            call_harness(a_harness_that_refuses, some_arguments())
        message = str(raised.exception)
        self.assertIn("TypeError", message)
        self.assertIn("force_rebuild", message)
        self.assertNotIn("memory", message)
        self.assertNotIn("137", message)
        self.assertIsInstance(raised.exception.cause, TypeError)
        self.assertEqual(len(calls), 1)

    def test_a_value_error_raises(self):
        def a_harness_that_refuses(**kw):
            raise ValueError("--modal cannot build from a task repo")

        with self.assertRaises(HarnessCallError):
            call_harness(a_harness_that_refuses, some_arguments())

    def test_a_docker_error_is_returned(self):
        error = a_docker_error("500 Server Error")

        def a_harness_that_fails(**kw):
            raise error

        self.assertIs(call_harness(a_harness_that_fails, some_arguments()), error)

    def test_a_missing_image_is_returned(self):
        error = a_harness_image_error("Image not found")

        def a_harness_that_fails(**kw):
            raise error

        self.assertIs(call_harness(a_harness_that_fails, some_arguments()), error)


class FailureKindTests(unittest.TestCase):
    """The kind of an error comes from its class, and memory from its text."""

    def test_a_subclass_of_a_docker_error_is_a_docker_failure(self):
        base = type("DockerException", (Exception,), {"__module__": "docker.errors"})
        child = type("ImageNotFound", (base,), {"__module__": "tests"})
        self.assertTrue(is_docker_failure(child("gone")))

    def test_a_type_error_is_not_a_docker_failure(self):
        self.assertFalse(is_docker_failure(TypeError("bad keyword")))

    def test_exit_137_is_a_memory_failure(self):
        self.assertTrue(is_memory_failure(a_docker_error("the build exited with code 137")))
        self.assertTrue(is_memory_failure(a_docker_error("container OOMKilled")))

    def test_an_other_docker_failure_is_not_a_memory_failure(self):
        self.assertFalse(is_memory_failure(a_docker_error("pull access denied")))


if __name__ == "__main__":
    unittest.main()
