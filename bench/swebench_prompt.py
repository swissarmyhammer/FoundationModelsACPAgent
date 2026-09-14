"""The prompt that one SWE-bench instance gives the agent.

The agent gets the problem statement of the instance. It also gets a short
instruction in front of that statement, and this module holds it.

WHY THE INSTRUCTION IS HERE, AND NOT IN THE AGENT
=================================================
The compiled-in instructions of the agent say, under `## Checks`:

    - Add or change a test for each change of behavior.

That rule is correct for the agent. A person who asks the agent to change
code wants a test with the change. So the tests the agent writes in a bench
run are OBEDIENCE, and not an accident.

But the SWE-bench scorer throws each one away. It restores the test files of
the instance from the base commit, and then it applies the official test
patch. So every line the agent writes below `tests/` is removed before one
test runs. The documents and the release notes are read by nothing.

The measurement, from the run of 2026-09-14, over the 7 instances that made
a patch:

    32 source lines of 184 added lines = 17%

83% of the work of the agent was deleted before the score. The instance
`django__django-14238` gave ONE correct source line and 22 test lines, and
it used 944 seconds to do it.

Time is not free here. The watchdog stops an instance at the limit, and
`django__django-14382` reached that limit with the correct one-line fix on
disk and more work still to do.

So the harness tells the agent what THIS task wants, because the task is not
an ordinary task of a person. The shipped instructions stay correct for
everybody else.

WHAT THE INSTRUCTION MAY NOT DO
===============================
It must not say what the fix is. It must not name a file, a symbol, or a
line. It says what to leave out, and nothing more. An instruction that
helped the agent find the answer would make the score a measure of the
prompt, and not of the agent.
"""

# The instruction that goes in front of the problem statement. It answers
# the `## Checks` rule of the agent for this task only, and it says why, so
# the agent does not read it as a contradiction.
BENCH_PREAMBLE = """\
This task is scored by a test suite that you cannot see and must not write.

- Change the SOURCE of the project only. Make the smallest change that
  fixes the issue.
- Write NO test. A test suite of its own scores this task, and it replaces
  every test file before it runs. A test that you write is deleted, and the
  time you use to write it is lost.
- Write NO release note, and change NO document.
- Do not report your work at the end. The change on disk is the answer.

The issue follows.\
"""

# The name of the prompt shape in the record of a run. A run records it, so
# two runs can be compared, and so a reader knows which prompt made a row.
PREAMBLE_NAME = "source-only-v1"

# The name a run records when it sends the problem statement alone.
PLAIN_NAME = "plain"


def instance_prompt(problem_statement, *, preamble=True):
    """The text of one instance, for `session/prompt`.

    - problem_statement: the statement of the instance, from the dataset.
    - preamble: whether to put ``BENCH_PREAMBLE`` in front of it.

    Returns the text to send. With no preamble it answers the statement
    unchanged, so a run can measure the agent against the plain task.
    """
    if not preamble:
        return problem_statement
    return f"{BENCH_PREAMBLE}\n\n{problem_statement}"


def prompt_name(preamble=True):
    """The name of the prompt shape, for the record row of an instance."""
    return PREAMBLE_NAME if preamble else PLAIN_NAME
