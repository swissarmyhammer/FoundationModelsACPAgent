"""The tests of the prompt that one instance gives the agent."""
import unittest

from swebench_prompt import (
    BENCH_PREAMBLE,
    PLAIN_NAME,
    PREAMBLE_NAME,
    instance_prompt,
    prompt_name,
)

A_STATEMENT = "AdminSite.catch_all_view() drops the query string."


class ThePromptOfAnInstance(unittest.TestCase):
    """What `instance_prompt` gives the agent."""

    def test_the_statement_is_at_the_end(self):
        """The problem statement stands, word for word, at the end."""
        text = instance_prompt(A_STATEMENT)
        self.assertTrue(text.endswith(A_STATEMENT))

    def test_the_preamble_is_in_front(self):
        """The instruction stands in front of the statement."""
        text = instance_prompt(A_STATEMENT)
        self.assertTrue(text.startswith(BENCH_PREAMBLE))
        self.assertLess(text.index(BENCH_PREAMBLE), text.index(A_STATEMENT))

    def test_a_blank_line_separates_the_two(self):
        """A blank line stands between the instruction and the statement."""
        self.assertIn(f"{BENCH_PREAMBLE}\n\n{A_STATEMENT}",
                      instance_prompt(A_STATEMENT))

    def test_no_preamble_gives_the_statement_alone(self):
        """`preamble=False` answers the statement, and nothing more."""
        self.assertEqual(instance_prompt(A_STATEMENT, preamble=False),
                         A_STATEMENT)


class TheInstructionSaysWhatToLeaveOut(unittest.TestCase):
    """The instruction may name no part of the answer."""

    def test_it_refuses_tests_documents_and_release_notes(self):
        """It names each kind of work the score throws away."""
        lowered = BENCH_PREAMBLE.lower()
        for word in ("test", "release note", "document"):
            self.assertIn(word, lowered)

    def test_it_names_no_file_of_a_project(self):
        """It names no path, so it cannot help the agent find the fix.

        An instruction that names a file makes the score a measure of the
        prompt. The words `tests` and `source` are about a KIND of file, and
        the guard here is for a path.
        """
        for mark in (".py", ".txt", "django/", "/"):
            self.assertNotIn(mark, BENCH_PREAMBLE)

    def test_it_is_short(self):
        """It stays small beside a problem statement, which runs to
        thousands of characters."""
        self.assertLess(len(BENCH_PREAMBLE), 700)


class TheNameOfThePrompt(unittest.TestCase):
    """The record row of an instance names the prompt it used."""

    def test_the_preamble_has_a_name(self):
        self.assertEqual(prompt_name(True), PREAMBLE_NAME)

    def test_the_plain_statement_has_a_name(self):
        self.assertEqual(prompt_name(False), PLAIN_NAME)

    def test_the_two_names_differ(self):
        """Two runs are comparable only when the names differ."""
        self.assertNotEqual(PREAMBLE_NAME, PLAIN_NAME)

    def test_the_name_carries_a_version(self):
        """A change of the words needs a change of the name, or an older
        row and a newer row read the same."""
        self.assertTrue(PREAMBLE_NAME[-1].isdigit())


if __name__ == "__main__":
    unittest.main()
