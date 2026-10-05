#!/usr/bin/env python3
"""Give the report of a SWE-bench score run of acp-agent.

The script reads these files. Only the score report is necessary:
- the score report: bench/preds.NAME.jsonl.score.<run id>.json
- the predictions: bench/preds.NAME.jsonl
- the record: bench/preds.NAME.runs.jsonl
- the kept transcripts: bench/preds.NAME.transcripts/<instance id>/
- the logs of the harness: logs/run_evaluation/<run id>/<model>/<instance id>/
- the agent config: bench/NAME.config.yaml
- a saved output of scan.py of the swebench skill (--scan FILE)

The output has these parts:
1. SCORE: resolved / evaluated, resolved / submitted, resolved / not empty.
2. INSTANCES: one row for each instance.
3. NOT RUN: the instances that the harness did not evaluate, with the cause.
   An empty patch is not a harness error. The harness does not send an
   empty patch to docker, so the score report puts it in `errored_ids`.
4. UNRESOLVED: the test counts of the harness for each unresolved instance.
5. WEB: a warning when web was on, and the instances where a web result
   looks like the upstream fix.
6. COMPARE: the change of each instance against the score of an other run.

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


def preds_of(arg, bench):
    """Give the predictions path of a NAME or of a path."""
    p = Path(arg)
    if p.suffix == ".jsonl" or p.exists():
        return p
    return Path(bench) / f"preds.{arg}.jsonl"


def all_preds(bench):
    """Give each predictions file in the bench dir. A record file is not a predictions file."""
    return [Path(p) for p in glob.glob(os.path.join(bench, "preds.*.jsonl"))
            if not p.endswith(".runs.jsonl")]


def score_files(preds):
    """Give the score reports of one predictions file, the oldest first."""
    return sorted(glob.glob(glob.escape(str(preds)) + ".score.*.json"), key=os.path.getmtime)


def newest_scored(bench):
    """Give the predictions file whose newest score report is the newest of all."""
    scored = [p for p in all_preds(bench) if score_files(p)]
    if not scored:
        return None
    return max(scored, key=lambda p: os.path.getmtime(score_files(p)[-1]))


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


def web_use(transcripts_dir):
    """Give {instance id: (web calls, [upstream evidence])} from the kept transcripts.

    The script pairs each runCode call with its result by the call id, as scan.py
    does. A web call is a `tools.web.<verb>` in the code of the call. The upstream
    evidence is a result of a web call that agrees with the UPSTREAM_RE of scan.py.
    """
    out = {}
    if scan is None or not os.path.isdir(transcripts_dir):
        return out
    pattern = os.path.join(transcripts_dir, "**", "transcript.jsonl")
    for f in sorted(glob.glob(pattern, recursive=True)):
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


def web_state(config):
    """Give the web state of a config: "on", "off", or "unknown" when there is no file."""
    if scan is None or not config.exists():
        return "unknown"
    _, _, web = scan.config_summary(scan.read_config(str(config)))
    return "off" if web == "false" else "on"


def harness_detail(root, run_id, iid):
    """Give a short text from the logs of the harness for one instance."""
    run_dir = Path(root) / LOGS_DIR / run_id
    if not run_dir.is_dir():
        return f"no harness logs for this run id ({run_dir} is missing)"
    hits = sorted(glob.glob(str(run_dir).replace("[", "[[]") + "/*/" + glob.escape(iid)))
    if not hits:
        return "no harness log: the image did not build, or the logs are gone"
    d = Path(hits[0])
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


def compare_target(arg, preds, bench, this_score):
    """Give the score report to compare with, or None.

    - arg: a score json path, a NAME, a predictions path, or None for the
      newest score of an other NAME that is older than this score.
    """
    if arg:
        if arg.endswith(".json") and Path(arg).exists():
            return Path(arg)
        files = score_files(preds_of(arg, bench))
        return Path(files[-1]) if files else None
    t = os.path.getmtime(this_score)
    other = [Path(f) for p in all_preds(bench) if name_of(p) != name_of(preds) for f in score_files(p)]
    older = [f for f in other if os.path.getmtime(f) <= t]
    pick = older or other
    return max(pick, key=os.path.getmtime) if pick else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", nargs="?", help="a run NAME (bench/preds.NAME.jsonl) or a predictions path")
    ap.add_argument("--bench", default="bench", help="the bench dir (default: bench)")
    ap.add_argument("--root", default=".", help="the dir where the harness wrote logs/ (default: .)")
    ap.add_argument("--score", help="the score report (default: the newest one of the predictions)")
    ap.add_argument("--scan", help="a saved output of scan.py; its upstream-fix items are added")
    ap.add_argument("--compare", help="a NAME, a predictions path or a score json to compare with "
                                      "(default: the newest score of an other NAME)")
    ap.add_argument("--no-compare", action="store_true", help="do not compare")
    a = ap.parse_args()

    if a.run:
        preds = preds_of(a.run, a.bench)
    elif a.score:
        preds = Path(re.sub(r"\.score\.[^/]*\.json$", "", a.score))
    else:
        preds = newest_scored(a.bench)
        if preds is None:
            print(f"no score report in {a.bench}/. Score a run first.")
            return 2
    files = [a.score] if a.score else score_files(preds)
    if not files or not Path(files[-1]).exists():
        print(f"no score report for {preds} (want {preds}.score.<run id>.json). Score the run first.")
        return 2
    score_path = Path(files[-1])
    name = name_of(preds)
    report, resolved, unresolved, errored = read_score(score_path)
    preds_rows = last_by_id(read_jsonl(preds))
    runs = last_by_id(read_jsonl(Path(str(preds)[: -len(".jsonl")] + ".runs.jsonl")))
    web = web_use(str(preds)[: -len(".jsonl")] + ".transcripts")
    if a.scan:
        for inst, ev in scan_upstream(a.scan).items():
            n, old = web.get(inst, (0, []))
            web[inst] = (n, old + [e for e in ev if e not in old])
    state = web_state(Path(a.bench) / f"{name}.config.yaml")
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
        print(f"  {i}: {harness_detail(a.root, run_id, i)}")
    if empty:
        print(f"  the empty patches are not sent to docker, so they are also in errored_ids: {', '.join(empty)}")

    print(f"\n== UNRESOLVED ({len(unresolved)}): the tests of the harness")
    for i in sorted(unresolved):
        print(f"  {i}: {harness_detail(a.root, run_id, i)}")

    used = sorted(i for i in ids if web.get(i, (0, []))[0])
    up = sorted(i for i in ids if web.get(i, (0, []))[1])
    print(f"\n== WEB: config {state}; web used in {len(used)} instance(s)")
    if state == "on" or used:
        print("  WARNING: web was on. A web result can hold the upstream fix, so this score")
        print("  does not measure the agent alone. Do not compare it with a run with web off.")
    for i in up:
        print(f"  upstream fix seen: {i} [{outcome(i, resolved, unresolved, errored, preds_rows)}]: "
              f"{'; '.join(web[i][1][:3])}")
    if up:
        clean = [i for i in resolved if i not in up]
        print(f"  resolved without an upstream fix seen: {len(clean)}/{ev} = {pct(len(clean), ev)}")

    if a.no_compare:
        return 0
    other = compare_target(a.compare, preds, a.bench, score_path)
    if other is None:
        print("\n== COMPARE: no other score report")
        return 0
    o_preds = Path(re.sub(r"\.score\.[^/]*\.json$", "", str(other)))
    o_report, o_res, o_unres, o_err = read_score(other)
    o_rows = last_by_id(read_jsonl(o_preds))
    o_state = web_state(Path(a.bench) / f"{name_of(o_preds)}.config.yaml")
    print(f"\n== COMPARE with {name_of(o_preds)} run id {o_report.get('run_id', '?')} ({other})")
    print(f"  before {len(o_res)}/{len(o_res) + len(o_unres)} resolved, now {len(resolved)}/{ev} resolved")
    if o_state != state:
        print(f"  WARNING: web is {o_state} before and {state} now; the two scores do not measure the same thing")
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
