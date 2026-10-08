#!/usr/bin/env python3
"""Give the report of a SWE-bench score run of acp-agent.

The script reads these files. Only the score report is necessary:
- the score report: bench/preds.NAME.jsonl.score.<run id>.json
- the predictions: bench/preds.NAME.jsonl
- the record: bench/preds.NAME.runs.jsonl
- the kept transcripts: bench/preds.NAME.transcripts/<instance id>/
- the logs of the harness: logs/run_evaluation/<run id>/<model>/<instance id>/
- the agent config of the run. The first source that names it wins:
  the `agent_config` field of the record, then the head of the run log
  bench/run.NAME.log (`agent_config=PATH` or `--agent-config PATH`), then
  bench/NAME.config.yaml
- a saved output of scan.py of the swebench skill (--scan FILE)

The output has these parts:
1. SCORE: resolved / evaluated, resolved / submitted, resolved / not empty.
2. INSTANCES: one row for each instance.
3. NOT RUN: the instances that the harness did not evaluate, with the cause.
   An empty patch is not a harness error. The harness does not send an
   empty patch to docker, so the score report puts it in `errored_ids`.
4. UNRESOLVED: the test counts of the harness for each unresolved instance.
5. WEB: the web state of the config, the instances that used web, and the
   instances where a web result looks like the upstream fix. This is
   information: the web tool is part of the agent, and a fix that the agent
   finds on the web and uses is a valid result.
6. GIT: the git state of the config, and each instance whose agent read a
   rev after the base commit (the `git_upstream_reads` field of the record).
   Such a read can show the upstream fix, and it is information too. The
   upstream-fix column of INSTANCES marks a web fix and a git read alike.
7. COMPARE: the change of each instance against the score of an other run.
   With no --compare, the other run is the newest other run with the same
   instance ids in its predictions file. A run with other instances does
   not measure the same thing. A run with web (or git) on and a run with it
   off use different tools, so their comparison is a comparison of two
   configurations.

Each path that the script builds or reads from input must resolve to a place
inside the repo root. The repo root is the dir that holds the bench dir. The
input is the command line, the record, the run log, and the file names in
the bench dir. The script stops with exit code 2 for a command line path
outside the repo root. It skips a path from a run file with a note on stderr.

Usage:
  python3 report.py code-context
  python3 report.py bench/preds.code-context.jsonl --compare web-off
  python3 report.py code-context --score FILE.json --scan scan.out
  python3 report.py            # the newest predictions file with a score

Use only the Python standard library.
"""
import argparse
import ast
import glob
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The scan of the swebench skill. This script uses its transcript helpers and
# its upstream-fix pattern, so that the two scripts find the same things.
SCAN_PATH = HERE.parents[1] / "swebench" / "scripts" / "scan.py"
# The harness writes its logs below the directory where it started.
LOGS_DIR = Path("logs") / "run_evaluation"
PREDS_NAME = re.compile(r"preds\.(.+)\.jsonl")
# The field of a record row that holds the --agent-config path of the run.
# swebench_record.py writes it. A record from before 2026-10-07 has no field.
CONFIG_FIELD = "agent_config"
# The field of a record row that holds the git reads of the agent past the base
# commit. swebench_record.py writes it. A record from before 2026-10-08 has no field.
GIT_FIELD = "git_upstream_reads"
# How many letters of a commit the evidence of a git read shows.
SHORT_SHA = 10
# The two tool groups whose state the report states: they can find the upstream fix.
WEB, GIT = "web", "git"
# The text in the run log that names the agent config: the log line of
# swebench_run.py, or the command line when a person put it in the log.
LOG_CONFIG = re.compile(r"(?:--agent-config[ =]|agent_config=)(\S+)")
# The log line that starts the agent on an instance. The lines after it can
# hold agent output, so the search for the config stops at this line.
LOG_AGENT_START = "running the agent"
# The line of scan.py that lists the upstream-fix results (5 items or fewer).
SCAN_UPSTREAM = re.compile(r"^== results that look like the upstream fix \(web\): \d+ (\[.*\])\s*$")
# The text of the harness log for each cause of a failure, first match wins.
HARNESS_CAUSES = (
    ("Patch Apply Failed", "the patch did not apply"),
    ("Error building image", "the image did not build"),
    ("timed out", "the tests timed out"),
    ("Traceback", "the harness raised an error"),
)
# The result names in the table.
RESOLVED, UNRESOLVED, EMPTY, NOT_RUN, ABSENT = "RESOLVED", "no", "EMPTY", "NOT RUN", "-"
# The names of the two dirs that a path must stay inside.
REPO_SCOPE = "the repo root"
LOGS_SCOPE = "the harness logs dir"
# The exit code for a usage error: no score report, or a path outside the repo.
USAGE_ERROR = 2


class OutsideRoot(ValueError):
    """A path from input that resolves to a place outside its permitted dir."""


def repo_root(bench):
    """Give the repo root: the resolved dir that holds the bench dir.

    - bench: the bench dir.
    """
    return Path(bench).resolve().parent


def confine(path, root, what, scope=REPO_SCOPE):
    """Give the resolved path. Raise OutsideRoot when it is not inside root.

    - path: the path to check. A relative path is relative to the current dir.
    - root: the resolved dir that the path must stay inside.
    - what: the name of the path in the message, for example "--score".
    - scope: the name of root in the message.

    resolve() removes each `..` and follows each link, so a path that only
    looks like it is inside root is refused too.
    """
    resolved = Path(path).resolve()
    if not resolved.is_relative_to(root):
        raise OutsideRoot(f"refused {what} {path}: it resolves to {resolved}, outside {scope} {root}")
    return resolved


def note(text):
    """Write a note to stderr. stdout holds only the report."""
    print(f"note: {text}", file=sys.stderr)


def inside_only(paths, root, what):
    """Give the resolved paths that are inside root. Write a note for each other path.

    - paths: the paths to check.
    - root: the resolved repo root.
    - what: the name of the paths in the note.
    """
    kept = []
    for p in paths:
        try:
            kept.append(confine(p, root, what))
        except OutsideRoot as e:
            note(f"skipped: {e}")
    return kept


def load_scan():
    """Load scan.py of the swebench skill as a module. Give None if it is missing."""
    if not SCAN_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("swebench_scan", SCAN_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scan = load_scan()


def read_jsonl(path):
    """Read a JSONL file. Skip a bad line. Give [] for a missing file."""
    rows = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return rows


def last_by_id(rows):
    """Give {instance id: row}. A later row of the same id replaces an earlier row."""
    return {r["instance_id"]: r for r in rows if isinstance(r, dict) and r.get("instance_id")}


def name_of(preds):
    """Give the run NAME of bench/preds.NAME.jsonl."""
    m = PREDS_NAME.fullmatch(Path(preds).name)
    return m.group(1) if m else Path(preds).stem


def preds_of(arg, bench, what):
    """Give the resolved predictions path of a NAME or of a path.

    - arg: a run NAME or a predictions path, from the command line.
    - bench: the bench dir.
    - what: the name of the argument in the message of a refusal.

    Raise OutsideRoot when the path is outside the repo root. A NAME can
    hold `..`, so the check is also necessary for bench/preds.NAME.jsonl.
    """
    p = Path(arg)
    if not (p.suffix == ".jsonl" or p.exists()):
        p = Path(bench) / f"preds.{arg}.jsonl"
    return confine(p, repo_root(bench), what)


def all_preds(bench):
    """Give each predictions file in the bench dir, resolved. A record file is not a predictions file.

    A file name in the bench dir can be a link to a place outside the repo
    root. The script skips such a file with a note.
    """
    found = [p for p in glob.glob(os.path.join(glob.escape(str(bench)), "preds.*.jsonl"))
             if not p.endswith(".runs.jsonl")]
    return inside_only(found, repo_root(bench), "predictions file")


def score_files(preds, root):
    """Give the resolved score reports of one predictions file, the oldest first.

    - preds: the resolved predictions path.
    - root: the resolved repo root.

    A score file name can be a link to a place outside the repo root. The
    script skips such a file with a note.
    """
    found = glob.glob(glob.escape(str(preds)) + ".score.*.json")
    return sorted(inside_only(found, root, "score report"), key=os.path.getmtime)


def newest_scored(bench):
    """Give the predictions file whose newest score report is the newest of all."""
    root = repo_root(bench)
    scored = [p for p in all_preds(bench) if score_files(p, root)]
    if not scored:
        return None
    return max(scored, key=lambda p: os.path.getmtime(score_files(p, root)[-1]))


def read_score(path):
    """Read a score report. Give (report, resolved ids, unresolved ids, errored ids).

    A report from before 2026-09-12 has a list at `errored` and no `errored_ids`.
    """
    d = json.loads(Path(path).read_text())
    errored = d.get("errored_ids")
    if errored is None:
        errored = d["errored"] if isinstance(d.get("errored"), list) else []
    return d, set(d.get("resolved_ids") or []), set(d.get("unresolved_ids") or []), list(errored)


def outcome(iid, resolved, unresolved, errored, preds_rows):
    """Give the result name of one instance in one score run."""
    if iid in resolved:
        return RESOLVED
    if iid in unresolved:
        return UNRESOLVED
    if iid in errored:
        patch = (preds_rows.get(iid) or {}).get("model_patch") or ""
        return EMPTY if not patch.strip() else NOT_RUN
    return ABSENT


def runcode_detail(text, ops):
    """Give the detail of a runCode result, as scan.py reads it."""
    try:
        c = json.loads(text)
    except ValueError:
        return text
    if not (isinstance(c, dict) and "completionToken" in c):
        return text
    detail = c.get("detail")
    if c.get("pending"):
        detail = ops.get(c.get("completionToken"))
    if detail is None:
        return ""
    return detail if isinstance(detail, str) else json.dumps(detail)


def web_use(transcripts_dir, root):
    """Give {instance id: (web calls, [upstream evidence])} from the kept transcripts.

    - transcripts_dir: the resolved transcripts dir of the run.
    - root: the resolved repo root.

    The script pairs each runCode call with its result by the call id, as scan.py
    does. A web call is a `tools.web.<verb>` in the code of the call. The upstream
    evidence is a result of a web call that agrees with the UPSTREAM_RE of scan.py.
    A transcript can be a link to a place outside the repo root. The script
    skips such a transcript with a note.
    """
    out = {}
    if scan is None or not os.path.isdir(transcripts_dir):
        return out
    pattern = os.path.join(glob.escape(str(transcripts_dir)), "**", "transcript.jsonl")
    found = sorted(glob.glob(pattern, recursive=True))
    for f in (str(p) for p in inside_only(found, root, "transcript")):
        inst = scan.instance_of(f)
        rows = read_jsonl(f)
        calls, ops = {}, {}
        for r in rows:
            if r.get("kind") == "toolCalls":
                for c in (r.get("entry") or {}).get("toolCalls") or []:
                    try:
                        args = json.loads(c.get("argumentsJSON") or "{}")
                    except (TypeError, ValueError):
                        args = {}
                    calls[c.get("id")] = args if isinstance(args, dict) else {}
            elif r.get("kind") == "toolOutput":
                m = scan.STATUS_RE.match(r.get("text", "") or "")
                if m and m.group(4) != "running":
                    ops[m.group(3)] = scan.detail_of(r.get("entry")) or r.get("text", "")
        n, evidence = out.get(inst, (0, []))
        for r in rows:
            if r.get("kind") != "toolOutput":
                continue
            cid = str((r.get("entry") or {}).get("entryId") or "")
            if cid not in calls:
                continue
            code = calls[cid].get("code") or ""
            webs = [v for v in (".".join(g) for g in scan.VERB_RE.findall(code)) if v.startswith("web.")]
            if not webs:
                continue
            n += len(webs)
            up = scan.UPSTREAM_RE.search(runcode_detail(scan.content_of(r), ops))
            if up:
                evidence.append(f"seq {r.get('seq')}: {up.group(0)[:70]}")
        out[inst] = (n, evidence)
    return out


def scan_upstream(path):
    """Give {instance id: [evidence]} from a saved output of scan.py.

    scan.py prints 5 items or fewer, so this list can be shorter than the truth.
    """
    out = {}
    for line in Path(path).read_text(errors="replace").splitlines():
        m = SCAN_UPSTREAM.match(line.strip())
        if not m:
            continue
        try:
            items = ast.literal_eval(m.group(1))
        except (ValueError, SyntaxError):
            continue
        for item in items:
            inst, _, rest = str(item).partition(" seq ")
            out.setdefault(inst, []).append(f"seq {rest[:80]} (scan)")
    return out


def beside(preds, suffix, root):
    """Give the resolved file of a run that stands beside its predictions file.

    - preds: bench/preds.NAME.jsonl.
    - suffix: the suffix that replaces `.jsonl`, for example `.runs.jsonl`.
    - root: the resolved repo root.

    Raise OutsideRoot when the file is outside the repo root.
    """
    return confine(Path(str(preds)[: -len(".jsonl")] + suffix), root, f"the {suffix} file of a run")


def run_ids(preds, root):
    """Give the set of instance ids of a run.

    - preds: the resolved predictions path.
    - root: the resolved repo root.

    The predictions file holds each instance of the run. A resumed score
    holds only the instances that it sent to docker, so the score ids are
    the fallback for a run with no predictions file.
    """
    ids = set(last_by_id(read_jsonl(preds)))
    files = score_files(preds, root)
    if ids or not files:
        return ids
    _, resolved, unresolved, errored = read_score(files[-1])
    return resolved | unresolved | set(errored)


def config_in_log(log):
    """Give the agent config path that the head of a run log names, or None.

    - log: bench/run.NAME.log.

    Only the lines before the agent starts on the first instance come from
    the run script. The lines after that can hold agent output, and agent
    output can hold any text.
    """
    try:
        with open(log, errors="replace") as f:
            for line in f:
                if LOG_AGENT_START in line:
                    return None
                m = LOG_CONFIG.search(line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def named_config(preds, bench, root):
    """Give the agent config path that the record or the run log names, or None.

    - preds: the resolved predictions path.
    - bench: the bench dir.
    - root: the resolved repo root.

    The path is the text of the file, with no check. Raise OutsideRoot when
    the record or the run log is outside the repo root.
    """
    named = next((r[CONFIG_FIELD] for r in read_jsonl(beside(preds, ".runs.jsonl", root))
                  if isinstance(r, dict) and r.get(CONFIG_FIELD)), None)
    log = confine(Path(bench) / f"run.{name_of(preds)}.log", root, "run log")
    return named or config_in_log(log)


def config_of(preds, bench):
    """Give the resolved path of the agent config that a run used, or None.

    - preds: the resolved predictions path.
    - bench: the bench dir.

    The first source that names a config wins: the `agent_config` field of
    the record, then the head of the run log, then bench/NAME.config.yaml.
    A record or a log gives the path as the run got it, relative to the dir
    where the run started. That dir is the repo root. A path outside the
    repo root, for example `../../etc/passwd`, is not read: the script
    writes a note and gives None, so the web state is unknown.
    """
    root = repo_root(bench)
    try:
        named = named_config(preds, bench, root)
        if named:
            return confine(root / str(named), root, "the agent config that the run names")
        by_name = confine(Path(bench) / f"{name_of(preds)}.config.yaml", root, "the config named after the run")
    except OutsideRoot as e:
        note(f"skipped: {e}; the web state of the run is unknown")
        return None
    return by_name if by_name.exists() else None


def tool_state(config, group):
    """Give the state of a tool group in a config: "on", "off", or "unknown" when there is no file.

    - config: the resolved path of the agent config, or None.
    - group: the name of the group below `tools`, for example "git".

    A group is on by default. scan.py reads the two forms that turn it off.
    """
    if scan is None or config is None or not config.exists():
        return "unknown"
    return "off" if scan.enabled_value(scan.read_config(str(config)), group) == "false" else "on"


def web_state(config):
    """Give the web state of a config: "on", "off", or "unknown" when there is no file."""
    return tool_state(config, WEB)


def git_state(config):
    """Give the git state of a config: "on", "off", or "unknown" when there is no file."""
    return tool_state(config, GIT)


def git_upstream(runs):
    """Give {instance id: [evidence]} of the git reads past the base commit.

    - runs: {instance id: record row}.

    The run checks each git read of the agent while the clone is there, and
    the record keeps the reads whose commit is not an ancestor of the base
    commit (`bench/swebench_history.py`). Such a read can show the upstream
    fix. That is a valid result, so this is information, as for web.
    """
    out = {}
    for iid, row in runs.items():
        reads = row.get(GIT_FIELD)
        evidence = [f"git {r.get('verb')} {r.get('rev')} ({str(r.get('commit'))[:SHORT_SHA]})"
                    for r in reads if isinstance(r, dict)] if isinstance(reads, list) else []
        if evidence:
            out[iid] = evidence
    return out


def git_checked(runs):
    """Give the count of record rows that hold the git check (a list, also an empty one)."""
    return sum(1 for row in runs.values() if isinstance(row.get(GIT_FIELD), list))


def print_git(config, runs, git, result_of):
    """Print the GIT part: the git state of the config, and each read past the base commit.

    - config: the resolved path of the agent config, or None.
    - runs: {instance id: record row}.
    - git: {instance id: [evidence]} from git_upstream.
    - result_of: gives the result name of an instance id.

    A record from before the check has no field, so the report says that it
    cannot tell, and not that the agent read no later rev.
    """
    checked = git_checked(runs)
    reads = (f"a read of the history after the base commit in {len(git)} instance(s) "
             f"({checked} of {len(runs)} record rows hold the check)") if checked else \
        "no git check in the record (a run from before 2026-10-08)"
    print(f"\n== GIT: config {git_state(config)} ({config or 'no config found for this run'}); {reads}")
    for i in sorted(git):
        print(f"  later history read: {i} [{result_of(i)}]: {'; '.join(git[i][:3])}")


def harness_detail(root, run_id, iid):
    """Give a short text from the logs of the harness for one instance.

    - root: the dir where the harness wrote logs/. main() keeps it inside the repo root.
    - run_id: the run id of the score report.
    - iid: the instance id.

    The run id and the instance id come from the score report, so each path
    that they make must stay inside the harness logs dir. The text of a
    refusal takes the place of the detail.
    """
    logs = Path(root).resolve() / LOGS_DIR
    try:
        run_dir = confine(logs / str(run_id), logs, "the run id", LOGS_SCOPE)
        if not run_dir.is_dir():
            return f"no harness logs for this run id ({run_dir} is missing)"
        hits = sorted(glob.glob(glob.escape(str(run_dir)) + "/*/" + glob.escape(iid)))
        if not hits:
            return "no harness log: the image did not build, or the logs are gone"
        d = confine(hits[0], logs, "the instance id", LOGS_SCOPE)
    except OutsideRoot as e:
        return str(e)
    rep = d / "report.json"
    if rep.exists():
        try:
            r = json.loads(rep.read_text()).get(iid, {})
        except ValueError:
            r = {}
        if r.get("patch_successfully_applied") is False:
            return "the patch did not apply"
        ts = r.get("tests_status") or {}
        parts = []
        for key in ("FAIL_TO_PASS", "PASS_TO_PASS"):
            g = ts.get(key) or {}
            ok, bad = len(g.get("success") or []), len(g.get("failure") or [])
            parts.append(f"{key} {ok}/{ok + bad}")
        return ", ".join(parts)
    log = d / "run_instance.log"
    text = log.read_text(errors="replace") if log.exists() else ""
    for key, why in HARNESS_CAUSES:
        if key in text:
            return why
    return f"no report.json; read {log}"


def pct(n, d):
    """Give n / d as a percentage text. Zero of zero is 0.0."""
    return f"{100.0 * n / d:.1f}%" if d else "0.0%"


def table(rows, head):
    """Print a plain table with columns of equal width."""
    w = [max(len(str(x)) for x in col) for col in zip(head, *rows)]
    for line in [head, ["-" * n for n in w], *rows]:
        print("  " + "  ".join(str(x).ljust(n) for x, n in zip(line, w)).rstrip())


def preds_of_score(score, root):
    """Give the resolved predictions path of a score report: the path without `.score.<run id>.json`.

    - score: the score report path.
    - root: the resolved repo root.

    Raise OutsideRoot when the score report or the predictions path is
    outside the repo root.
    """
    resolved = confine(score, root, "score report")
    return confine(re.sub(r"\.score\.[^/]*\.json$", "", str(resolved)), root, "the predictions file of a score")


def compare_target(arg, preds, bench, this_score):
    """Give (the score report to compare with or None, why the report took it).

    - arg: a score json path, a NAME or a predictions path from --compare,
      or None.
    - preds: the resolved predictions path of this run.
    - bench: the bench dir.
    - this_score: the score report of this run.

    With no arg, the target is the newest score of the newest other run with
    the same instance ids. A score that is older than this score comes first.
    A run with other instances does not measure the same thing, so it is
    never the target. Raise OutsideRoot when arg is outside the repo root.
    """
    root = repo_root(bench)
    named = "named with --compare"
    if arg:
        if arg.endswith(".json") and Path(arg).exists():
            return confine(arg, root, "--compare"), named
        files = score_files(preds_of(arg, bench, "--compare"), root)
        return (files[-1] if files else None), named
    ids = run_ids(preds, root)
    same = [score_files(p, root)[-1] for p in all_preds(bench)
            if name_of(p) != name_of(preds) and score_files(p, root) and run_ids(p, root) == ids]
    if not same:
        return None, f"no other run has the same {len(ids)} instance ids; name one with --compare NAME"
    t = os.path.getmtime(this_score)
    older = [f for f in same if os.path.getmtime(f) <= t]
    return max(older or same, key=os.path.getmtime), f"the newest other run with the same {len(ids)} instance ids"


def main(argv=None):
    """Print the report of one score run. Give the exit code.

    - argv: the command line arguments, or None for sys.argv.
    """
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", nargs="?", help="a run NAME (bench/preds.NAME.jsonl) or a predictions path")
    ap.add_argument("--bench", default="bench", help="the bench dir (default: bench)")
    ap.add_argument("--root", default=".", help="the dir where the harness wrote logs/ (default: .)")
    ap.add_argument("--score", help="the score report (default: the newest one of the predictions)")
    ap.add_argument("--scan", help="a saved output of scan.py; its upstream-fix items are added")
    ap.add_argument("--compare", help="a NAME, a predictions path or a score json to compare with "
                                      "(default: the newest other run with the same instance ids)")
    ap.add_argument("--no-compare", action="store_true", help="do not compare")
    a = ap.parse_args(argv)
    try:
        return print_report(a)
    except OutsideRoot as e:
        print(f"error: {e}", file=sys.stderr)
        return USAGE_ERROR


def print_report(a):
    """Print the report of one score run. Give the exit code.

    - a: the parsed command line arguments.

    Raise OutsideRoot when a path from the command line is outside the repo root.
    """
    root = repo_root(a.bench)
    logs_root = confine(a.root, root, "--root")
    scan_path = confine(a.scan, root, "--scan") if a.scan else None
    score_arg = confine(a.score, root, "--score") if a.score else None
    if a.run:
        preds = preds_of(a.run, a.bench, "the run")
    elif score_arg:
        preds = preds_of_score(score_arg, root)
    else:
        preds = newest_scored(a.bench)
        if preds is None:
            print(f"no score report in {a.bench}/. Score a run first.")
            return USAGE_ERROR
    files = [score_arg] if score_arg else score_files(preds, root)
    if not files or not files[-1].exists():
        print(f"no score report for {preds} (want {preds}.score.<run id>.json). Score the run first.")
        return USAGE_ERROR
    score_path = files[-1]
    name = name_of(preds)
    report, resolved, unresolved, errored = read_score(score_path)
    preds_rows = last_by_id(read_jsonl(preds))
    runs = last_by_id(read_jsonl(beside(preds, ".runs.jsonl", root)))
    web = web_use(beside(preds, ".transcripts", root), root)
    if scan_path:
        for inst, ev in scan_upstream(scan_path).items():
            n, old = web.get(inst, (0, []))
            web[inst] = (n, old + [e for e in ev if e not in old])
    git = git_upstream(runs)
    config = config_of(preds, a.bench)
    state = web_state(config)
    run_id = report.get("run_id", "?")

    ids = sorted(resolved | unresolved | set(errored)) or sorted(preds_rows)
    empty = [i for i in errored if not ((preds_rows.get(i) or {}).get("model_patch") or "").strip()]
    not_run = [i for i in errored if i not in empty]
    nonempty = [i for i in ids if ((preds_rows.get(i) or {}).get("model_patch") or "").strip()]
    ev = len(resolved) + len(unresolved)

    print(f"== SCORE {name}  run id {run_id}  ({score_path})")
    print(f"  resolved / evaluated : {len(resolved)}/{ev} = {pct(len(resolved), ev)}")
    print(f"  resolved / submitted : {len(resolved)}/{len(ids)} = {pct(len(resolved), len(ids))}")
    print(f"  resolved / not empty : {len(resolved)}/{len(nonempty)} = {pct(len(resolved), len(nonempty))}")
    print(f"  unresolved {len(unresolved)}, empty patch {len(empty)}, not run (harness) {len(not_run)}, "
          f"wall {report.get('wall_minutes', 0):.1f} min")

    print(f"\n== INSTANCES ({len(ids)})")
    rows = []
    for i in ids:
        r = runs.get(i) or {}
        p = (preds_rows.get(i) or {}).get("model_patch") or ""
        n, upv = web.get(i, (0, []))
        upv = upv + git.get(i, [])
        stop = r.get("stop_reason") or "?"
        if r.get("timed_out"):
            stop += " (timeout)"
        secs = r.get("seconds")
        rows.append([i, outcome(i, resolved, unresolved, errored, preds_rows), len(p.encode()),
                     f"{secs:.0f}" if isinstance(secs, (int, float)) else "?", stop,
                     f"y ({n})" if n else "n", "YES" if upv else ""])
    table(rows, ["instance", "result", "patch B", "secs", "stop", "web", "upstream fix"])

    print(f"\n== NOT RUN by the harness ({len(not_run)}); these are not agent failures")
    for i in not_run:
        print(f"  {i}: {harness_detail(logs_root, run_id, i)}")
    if empty:
        print(f"  the empty patches are not sent to docker, so they are also in errored_ids: {', '.join(empty)}")

    print(f"\n== UNRESOLVED ({len(unresolved)}): the tests of the harness")
    for i in sorted(unresolved):
        print(f"  {i}: {harness_detail(logs_root, run_id, i)}")

    used = sorted(i for i in ids if web.get(i, (0, []))[0])
    up = sorted(i for i in ids if web.get(i, (0, []))[1])
    print(f"\n== WEB: config {state} ({config or 'no config found for this run'}); "
          f"web used in {len(used)} instance(s)")
    for i in up:
        print(f"  upstream fix seen: {i} [{outcome(i, resolved, unresolved, errored, preds_rows)}]: "
              f"{'; '.join(web[i][1][:3])}")
    print_git(config, runs, git, lambda i: outcome(i, resolved, unresolved, errored, preds_rows))
    if up or git:
        # Information only: how the agent solved these instances. The web and
        # git tools are part of the agent, so each of them is a valid result.
        with_fix = [i for i in resolved if i in up or i in git]
        print(f"  resolved with an upstream fix seen (web or git): {len(with_fix)} of {len(resolved)} resolved")

    if a.no_compare:
        return 0
    other, why = compare_target(a.compare, preds, a.bench, score_path)
    if other is None:
        print(f"\n== COMPARE: no other score report: {why}")
        return 0
    o_preds = preds_of_score(other, root)
    o_report, o_res, o_unres, o_err = read_score(other)
    o_rows = last_by_id(read_jsonl(o_preds))
    o_config = config_of(o_preds, a.bench)
    print(f"\n== COMPARE with {name_of(o_preds)} run id {o_report.get('run_id', '?')} ({other})")
    print(f"  the report took this run because it is {why}")
    print(f"  before {len(o_res)}/{len(o_res) + len(o_unres)} resolved, now {len(resolved)}/{ev} resolved")
    for group in (WEB, GIT):
        before, now = tool_state(o_config, group), tool_state(config, group)
        if before != now:
            print(f"  {group} is {before} before and {now} now: the two runs use different tools, "
                  f"so this is a comparison of two configurations")
    o_ids = o_res | o_unres | set(o_err)
    rows, count = [], {"fixed": 0, "broken": 0, "same": 0, "not run": 0, "only one run": 0}
    for i in sorted(set(ids) | o_ids):
        before = outcome(i, o_res, o_unres, o_err, o_rows)
        now = outcome(i, resolved, unresolved, errored, preds_rows)
        if ABSENT in (before, now):
            delta = "only one run"
        elif NOT_RUN in (before, now):
            # A harness error is not a result of the agent, so it is not "same".
            delta = "not run"
        elif now == RESOLVED and before != RESOLVED:
            delta = "fixed"
        elif before == RESOLVED and now != RESOLVED:
            delta = "broken"
        else:
            delta = "same"
        count[delta] += 1
        rows.append([i, before, now, delta])
    table(rows, ["instance", "before", "now", "delta"])
    print("  " + ", ".join(f"{k} {v}" for k, v in count.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
