"""
swebench_history.py -- find each git read of the agent that reaches past the
base commit of an instance.

`swebench_run.py` makes a FULL clone of the project, and then checks out the
base commit. The HEAD of the clone is thus detached at the base commit, but the
clone also holds the later history: the local branch `main`, the remote
branches such as `origin/main`, and the tags. The git tools of the agent
(`tools.git.log`, `show`, `blame`, `commit`, `changes` and `diff`) take a rev
argument, so a read of such a rev can show the upstream fix of the issue.

The user decided that an upstream fix that the agent finds is a valid result,
as for the web tool (task ^exkkyyr). The run does not block the read. It
records it: this module finds each such read while the clone is still there,
and the record of the instance keeps the list. The score report then marks the
instance in its upstream-fix column. After the instance, the run removes the
clone, so a later check of the ancestry is not possible.

A read is "upstream" when its rev names a commit that is NOT an ancestor of
the base commit, and that a remote branch or a tag of the clone holds. The
second condition keeps the commits of the agent itself out: the agent can
commit its change on the detached HEAD, and such a commit is in no remote
branch and no tag.

The module reads the revs from the code of each runCode call in the
transcripts of the agent. It sees a rev that the code writes as a string
literal in the argument object of the call. A rev in a variable, or in a
template with a `${...}` part, is out of its sight.

This module needs the standard library only.
"""
import json
import re
import subprocess
from pathlib import Path

# The git program. A test replaces it to make a run with no git.
GIT = "git"
# The longest time of one git command, in seconds. Each command reads the
# local clone only, so a longer time is a fault of the machine.
GIT_SECONDS = 60
# The file name of one transcript.
TRANSCRIPT_NAME = "transcript.jsonl"
# The kind of the transcript row that holds the tool calls of the model.
TOOL_CALLS_KIND = "toolCalls"
# One call of a git verb, and its argument object when the object holds no
# other object. Group 1 is the verb, and group 2 is the object.
GIT_CALL = re.compile(r"\btools\.git\.([A-Za-z_]+)\s*\(\s*(\{[^{}]*\})?")
# One argument of the object that names a rev, with its string value. Group 1
# is the key, and group 3 is the value. The key can have quotes (the JSON form).
REV_ARGUMENT = re.compile(r"""(?:^|[{,\s])["']?(ref|rev|range|branch|left|right)["']?\s*:\s*(["'`])(.*?)\2""")
# The keys whose value is a path, with the rev after the first `@`
# (`tools.git.diff`, `left: "a.py@main"`). A value with no `@` is a path of
# the work folder, which is no rev.
PATH_REF_KEYS = ("left", "right")
# The key whose value is a range: `from..to`, `from...to`, or one rev.
RANGE_KEY = "range"
# The separator of the two ends of a range.
RANGE_SEPARATOR = re.compile(r"\.{2,3}")
# The separator of a path and its rev in a path argument.
PATH_REF_SEPARATOR = "@"
# The refs whose commits are the history of the project: the remote branches
# and the tags of the clone.
UPSTREAM_REFS = ("refs/remotes", "refs/tags")
# The start of a command-line option. A rev from the model that starts with
# it must not go to git, which would read it as an option.
OPTION_PREFIX = "-"
# The exit code of `git merge-base --is-ancestor` when the first commit is an
# ancestor of the second.
IS_ANCESTOR = 0


def revs_of(key, value):
    """Give the revs that one rev argument names.

    - key: the name of the argument, for example "ref" or "range".
    - value: the string value of the argument.

    A range gives its two ends. An empty end is HEAD, and HEAD is the clone
    itself, so it gives no rev. A path argument gives the part after its
    first `@`, or no rev when it has no `@`.
    """
    if key in PATH_REF_KEYS:
        _, at, rev = value.partition(PATH_REF_SEPARATOR)
        return [rev] if at and rev else []
    if key == RANGE_KEY:
        return [end for end in RANGE_SEPARATOR.split(value) if end]
    return [value] if value else []


def git_reads(code):
    """Give each (verb, rev) that one snippet reads with a git verb, in order.

    - code: the JavaScript of one runCode call.
    """
    reads = []
    for call in GIT_CALL.finditer(code or ""):
        verb, arguments = call.group(1), call.group(2) or ""
        for argument in REV_ARGUMENT.finditer(arguments):
            reads += [(verb, rev) for rev in revs_of(argument.group(1), argument.group(3))]
    return reads


def call_codes(row):
    """Give the code of each runCode call in one transcript row.

    - row: one parsed line of a transcript.

    A row of another kind, or a row with an other shape, gives no code. The
    run calls this before it removes the clone, so a bad row must not stop
    the run.
    """
    is_calls = isinstance(row, dict) and row.get("kind") == TOOL_CALLS_KIND
    entry = row.get("entry") if is_calls else None
    calls = entry.get("toolCalls") if isinstance(entry, dict) else None
    codes = []
    for call in calls if isinstance(calls, list) else []:
        try:
            arguments = json.loads(call.get("argumentsJSON") or "{}")
        except (AttributeError, TypeError, ValueError):
            continue
        if isinstance(arguments, dict) and isinstance(arguments.get("code"), str):
            codes.append(arguments["code"])
    return codes


def snippet_codes(transcripts):
    """Give the code of each runCode call in the transcripts below a dir.

    - transcripts: the transcripts dir of the agent in the clone.

    A line that is not JSON is skipped: the agent can stop in the middle of a
    line.
    """
    for path in sorted(Path(transcripts).rglob(TRANSCRIPT_NAME)):
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            yield from call_codes(row)


def git_output(repo, *args):
    """Run one git command in the clone. Give (exit code, standard output).

    - repo: the clone.
    - args: the arguments of the git command. Each one is a list item, so no
      shell reads them.

    Raise OSError when git does not start, and subprocess.TimeoutExpired when
    it runs longer than GIT_SECONDS.
    """
    done = subprocess.run(
        [GIT, "-C", str(repo), *args],
        capture_output=True, text=True, timeout=GIT_SECONDS,
    )
    return done.returncode, done.stdout.strip()


def upstream_commit(repo, base_commit, rev):
    """Give the commit of rev when it is upstream history, else None.

    - repo: the clone.
    - base_commit: the base commit of the instance.
    - rev: a rev that the agent read.

    The commit is upstream when it is not an ancestor of the base commit, and
    a remote branch or a tag holds it. A rev that names no commit gives None:
    the git tool then gave a correction, and the agent read nothing.
    """
    if rev.startswith(OPTION_PREFIX):
        return None
    code, commit = git_output(repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}")
    if code != 0 or not commit:
        return None
    code, _ = git_output(repo, "merge-base", "--is-ancestor", commit, base_commit)
    if code == IS_ANCESTOR:
        return None
    _, holders = git_output(repo, "for-each-ref", "--count=1", "--contains", commit, *UPSTREAM_REFS)
    return commit if holders else None


def upstream_reads(repo, base_commit, transcripts):
    """Give each git read of the agent that reaches the upstream history.

    - repo: the clone of the instance, before the run removes it.
    - base_commit: the base commit of the instance.
    - transcripts: the transcripts dir of the agent in the clone.

    Give a list of {"verb", "rev", "commit"}, one row for each distinct
    (verb, rev), in the order of the first read. Give [] when the agent read
    no such rev, and None when the check could not run (a transcript that
    cannot be read, no git, or a git command that did not end in time).
    """
    found = []
    try:
        reads = dict.fromkeys(r for code in snippet_codes(transcripts) for r in git_reads(code))
        for verb, rev in reads:
            commit = upstream_commit(repo, base_commit, rev)
            if commit:
                found.append({"verb": verb, "rev": rev, "commit": commit})
    except (OSError, subprocess.SubprocessError):
        return None
    return found
