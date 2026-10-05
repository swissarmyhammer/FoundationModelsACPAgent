#!/usr/bin/env python3
"""Scan a SWE-bench run of acp-agent. Use it while the run continues or after it stops.

The scan reads these files. Each one is optional:
  - the run log (bench/run.<name>.log)
  - the predictions (bench/preds.<name>.jsonl) and the record (bench/preds.<name>.runs.jsonl)
  - the kept transcripts (bench/preds.<name>.transcripts/<instance_id>/)
  - the live transcripts in the clone of the instance that runs now (--live)
  - the recordings of the tool-selection model ($TMPDIR/acp-agent-recordings-*/)
  - the agent config (bench/<name>.config.yaml). The scan reads the file as it
    is now. When the file changed after the run started, the scan gives a
    warning, shows the config in git before the run start, and marks each
    config problem as not sure.

A missing file gives a note. It does not stop the scan. On a live run, the
last JSONL line can be partial. The scan skips that line.

The output has three parts:
  1. PROBLEMS: a ranked list. Each item has its evidence.
  2. PROGRESS: done / total, time of each instance, the instance that runs now.
  3. TOOLS: calls and errors for each tool and each tools.<group>.<verb>. The
     verbs come from the code of each runCode call (the "toolCalls" lines
     keep it). The scan pairs each call with its result by the call id.

Usage:
  python3 scan.py --name code-context --live
  python3 scan.py --log bench/run.x.log --transcripts DIR [DIR ...] --preds FILE
Use only the Python standard library.
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
import time

APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
WATCHER = "could not mark a changed file dirty"
# The prefix of a tool result line in the transcript:
#   [runCode] runCode (01M45...) completed: {...}
#   [execute] execute shell (01M45...) running: stdout: ...
# Read the status from this prefix only. A grep result can quote other
# results that contain the word "running:".
STATUS_RE = re.compile(r"^\[([^\]]+)\]\s+(.+?)\s+\(([0-9A-Za-z-]+)\)\s+(running|completed|failed)\b")
VERB_RE = re.compile(r"\btools\.([a-z_]+)\.([a-zA-Z_]+)\b")
NOT_FN_RE = re.compile(r"(tools\.[a-z_]+\.[a-zA-Z_]+) is not a function")
# The start of a runCode result when the snippet did not run to its end.
SNIPPET_FAIL = "The snippet failed:"
# A tool argument that is not valid, for example:
#   __tool2: Tool "edit" argument "find" must be array, got a string instead.
ARG_FAIL_RE = re.compile(r'Tool "([A-Za-z_]+)" argument|argument validation failed|'
                         r"must be (?:an? )?(?:array|string|number|object|boolean|integer), got", re.I)
# The status values of a JSON result that tell of a failure.
FAIL_STATUS = ("failed", "failure", "error", "timedout", "timed out", "cancelled", "canceled")
RUN_LOG_TIME = re.compile(r"^(\d\d:\d\d:\d\d) ")
AGENT_LOG = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)[-+]\d{4} (\w+) ([\w.]+): (.*)$")
FIELD_RE = re.compile(r"\b([\w.]+)=(\S+)")
# The optional web key variables. Web search works with no key.
# Signs that a result holds the upstream fix of the issue: a git
# format-patch header, a commit page, or a closed ticket with a commit.
UPSTREAM_RE = re.compile(r"From [0-9a-f]{40} Mon Sep 17 00:00:00 2001|github\.com/[\w.-]+/[\w.-]+/(commit|pull)/[0-9a-f]{7,}|"
                         r"Status: \| assigned \u2192 closed|Resolution: \| \u2192 fixed|/changeset/[0-9a-f]{7,}")
WEB_KEYS = ("BRAVE_SEARCH_API_KEY", "TAVILY_API_KEY", "EXA_API_KEY", "SERPER_API_KEY", "KAGI_API_KEY", "SEARXNG_URL")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def note(msg):
    print(f"  note: {msg}")


def ts(t):
    """Change a transcript time (seconds since 2001-01-01 UTC) to a datetime."""
    try:
        return APPLE_EPOCH + dt.timedelta(seconds=float(t))
    except (TypeError, ValueError):
        return None


def read_jsonl(path):
    """Read a JSONL file. Skip a partial or bad line. Give [] for a missing file."""
    rows = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass  # A live run can write half of the last line.
    except OSError as e:
        note(f"cannot read {path}: {e}")
    return rows


def read_lines(path):
    try:
        with open(path, errors="replace") as f:
            return [ANSI.sub("", l.rstrip("\n")) for l in f]
    except OSError as e:
        note(f"cannot read {path}: {e}")
        return []


def sh(cmd, timeout=10):
    """Run a short shell command. Give its output, or "" if it fails."""
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.SubprocessError, OSError):
        return ""


# ---------------------------------------------------------------- config

def read_config(path, text=None):
    """Read the small YAML subset of an agent config: maps and scalars.

    Give a dict of dotted keys, for example {"tools.web.enabled": "true"}.
    Lists are not read; this scan does not need them. With text, read the
    text in place of the file.
    """
    out = {}
    stack = []  # (indent, key)
    raw_lines = text.splitlines() if text is not None else (read_lines(path) if path else [])
    for raw in raw_lines:
        line = raw.split(" #")[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip() or line.strip().startswith("-"):
            continue
        indent = len(line) - len(line.lstrip())
        m = re.match(r"\s*([\w.-]+):\s*(.*)$", line)
        if not m:
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()
        key = ".".join([k for _, k in stack] + [m.group(1)])
        if m.group(2):
            out[key] = m.group(2).strip().strip("\"'")
        else:
            stack.append((indent, m.group(1)))
            out.setdefault(key, None)
    return out


def config_summary(cfg):
    """Give (the groups that are off, the value of tools.web.enabled) of a config."""
    groups = sorted({k.split(".")[1] for k in cfg if k.startswith("tools.") and k.count(".") >= 1})
    off = [g for g in groups if str(cfg.get(f"tools.{g}.enabled", "")).lower() == "false"]
    return groups, off, str(cfg.get("tools.web.enabled", "")).lower()


def config_problem(R, score, what, evidence):
    """Add a problem that comes from the config file.

    When the config file changed after the run started, the file now can
    differ from the config of the run. Then the problem is not a sure fact:
    mark it, and give it a lower rank.
    """
    if R.get("config_changed"):
        score -= 30
        what = f"{what} [not sure: config changed after the run started]"
        evidence = f"{evidence}; {R['config_changed']}"
    R["problems"].append((score, what, evidence))


def harness_config():
    """Give the --agent-config of each live harness process."""
    out = []
    for l in sh("ps -axo command").splitlines():
        if "swebench_run.py" in l:
            m = re.search(r"--agent-config[ =](\S+)", l)
            out.append(m.group(1) if m else "(no --agent-config: the default config)")
    return out


def scan_config(path, R, start=None):
    print(f"== config {path or '(none)'}")
    live = harness_config()
    if live:
        print(f"  --agent-config of the live harness: {', '.join(live)}")
    if not path:
        note("no --config. The run uses the default config of the agent.")
        R["web_enabled"] = None
        return
    if not os.path.exists(path):
        note(f"missing {path}")
        R["web_enabled"] = None
        return
    mtime = dt.datetime.fromtimestamp(os.path.getmtime(path))
    print(f"  file changed at {mtime:%Y-%m-%d %H:%M:%S}; run started at "
          f"{f'{start:%Y-%m-%d %H:%M:%S}' if start else '? (no run log time)'}")
    if start and mtime > start:
        R["config_changed"] = (f"{path} changed at {mtime:%Y-%m-%d %H:%M:%S}, "
                               f"after the run started at {start:%Y-%m-%d %H:%M:%S}")
        print("  WARNING: the config file changed after the run started. The run can have used another config.")
        print("   The values below are the values of the file now. The scan marks each config problem as not sure.")
        rev = sh(f"git log -1 --format='%h %ci' --before='{start:%Y-%m-%d %H:%M:%S}' -- '{path}'").strip()
        if rev:
            rel = path if os.path.isabs(path) else "./" + path
            old = read_config(None, sh(f"git show '{rev.split()[0]}:{rel}'"))
            _, old_off, old_web = config_summary(old)
            print(f"  the config in git at the last commit before the run started ({rev}):")
            print(f"   groups that are off: {', '.join(old_off) or '(none)'}; "
                  f"tools.web.enabled = {old_web or '(not set: on by default)'}")
            print("   (the run can also have used a copy that was not committed)")
    cfg = read_config(path)
    groups, off, web = config_summary(cfg)
    # The web group is on by default. Only "enabled: false" turns it off.
    R["web_enabled"] = web != "false"
    print(f"  tool groups in the file: {', '.join(groups) or '(none)'}")
    print(f"  groups that are off: {', '.join(off) or '(none)'}")
    print(f"  tools.web.enabled = {web or '(not set: on by default)'}")
    for k in ("tools.codeContext.semanticSearch", "tools.codeContext.autoInstall"):
        if k in cfg:
            print(f"  {k} = {cfg[k]}")
    keys = [k for k in WEB_KEYS if os.environ.get(k)]
    print(f"  web key variables set in this shell (names only): {', '.join(keys) or 'none: the keyless Brave/DuckDuckGo pages'}")
    print("   (the harness gives the agent a clean environment; see bench/swebench_env.py for what it keeps)")
    prov = {k: v for k, v in cfg.items() if k.startswith("tools.web.") and k != "tools.web.enabled" and v}
    if prov:
        print(f"  web settings (values not shown): {', '.join(sorted(prov))}")
    for g in off:
        config_problem(R, 90 if g == "web" else 60, f"config turns off the tool group '{g}'",
                       f"{path}: tools.{g}.enabled: false")


# ---------------------------------------------------------------- run log

def log_clock(lines):
    """Give the datetime of each HH:MM:SS run-log line. Correct for a day change."""
    out = []
    day = dt.date.today()
    prev = None
    stamps = []
    for l in lines:
        m = RUN_LOG_TIME.match(l)
        if m:
            t = dt.time.fromisoformat(m.group(1))
            stamps.append(t)
    # Count the day changes, then set the first day so that the last line is today.
    changes = sum(1 for a, b in zip(stamps, stamps[1:]) if b < a and (dt.datetime.combine(day, a) - dt.datetime.combine(day, b)).total_seconds() > 3600)
    cur = day - dt.timedelta(days=changes)
    for l in lines:
        m = RUN_LOG_TIME.match(l)
        if not m:
            out.append(None)
            continue
        t = dt.time.fromisoformat(m.group(1))
        if prev and t < prev and (dt.datetime.combine(cur, prev) - dt.datetime.combine(cur, t)).total_seconds() > 3600:
            cur = cur + dt.timedelta(days=1)
        prev = t
        out.append(dt.datetime.combine(cur, t))
    return out


def run_start(path):
    """Give the time of the first timed line of the run log, or None."""
    if not path or not os.path.exists(path):
        return None
    lines = read_lines(path)
    return next((c for c in log_clock(lines) if c), None)


def scan_log(path, timeout, R):
    print(f"== run log {path or '(none)'}")
    if not path or not os.path.exists(path):
        note("missing run log")
        return
    lines = read_lines(path)
    clock = log_clock(lines)
    now = dt.datetime.now()
    first = next((c for c in clock if c), None)
    last = next((c for c in reversed(clock) if c), None)
    agent_times = []
    for l in lines:
        m = AGENT_LOG.match(l)
        if m:
            agent_times.append(dt.datetime.fromisoformat(m.group(1)))
    t0 = min([t for t in [first] + agent_times[:1] if t] or [None]) if (first or agent_times) else None
    span_h = max(((now - t0).total_seconds() / 3600) if t0 else 0, 1 / 60)
    if agent_times:
        last = max([t for t in (last, max(agent_times)) if t])
    print(f"  lines={len(lines)} first={first:%H:%M:%S} last={last:%H:%M:%S}" if first and last else f"  lines={len(lines)}")
    R["log_mtime_age"] = time.time() - os.path.getmtime(path)
    if first:
        R["start_epoch"] = first.timestamp()

    # Instances: start, end, and the shape of the end.
    total = None
    started = collections.OrderedDict()
    ended = {}
    for l, c in zip(lines, clock):
        f = dict(FIELD_RE.findall(l))
        if "the instances of this run" in l:
            total = f.get("to_do") or f.get("instances")
        inst = f.get("instance")
        if not inst:
            continue
        if "running the agent..." in l:
            started[inst] = (c, f.get("number"), f.get("of"), int(f.get("limit_seconds", timeout) or timeout))
            total = total or f.get("of")
        for key, tag in (("TOO SLOW", "timeout"), ("EMPTY patch", "empty"), (" done ", "done"),
                         ("ERROR", "error"), ("NO ENVIRONMENT", "no-env"), ("not supported here", "unsupported"),
                         ("done already", "skipped")):
            if key in l and "running the agent" not in l:
                ended[inst] = (c, tag, f.get("seconds"), l[:220])
                break
    R["started"], R["ended"], R["total"] = started, ended, total
    complete = any(" complete" in l and "instances" not in l for l in lines[-40:]) or any("[bold]complete" in l for l in lines)
    R["complete"] = complete or any(re.search(r"^\d\d:\d\d:\d\d complete\b", l) for l in lines)

    # The watcher warning: count it alone. It is noisy.
    w = [(l, c) for l, c in zip(lines, clock) if WATCHER in l]
    wfiles = set()
    per_min = collections.Counter()
    per_sec = collections.Counter()
    etypes = collections.Counter()
    for l, _ in w:
        f = dict(FIELD_RE.findall(l))
        if "file.path" in f:
            wfiles.add(f["file.path"])
        etypes[f.get("error.type", "?")] += 1
        m = AGENT_LOG.match(l)
        stamp = m.group(1) if m else l[:19]
        per_min[stamp[11:16]] += 1
        per_sec[stamp[11:19]] += 1
    R["watcher_files"] = wfiles
    print(f"  watcher warnings '{WATCHER}': {len(w)}")
    if w:
        peak = per_sec.most_common(1)[0]
        print(f"   unique files {len(wfiles)}; error types {dict(etypes)}")
        print(f"   per minute (top 6) {dict(per_min.most_common(6))}; peak {peak[1]}/s at {peak[0]}")
        print("   the log keeps only the error type; the detail of CodeContextError is lost")
        R["problems"].append((55, f"watcher burst: {len(w)} '{WATCHER}' warnings, {len(wfiles)} files, peak {peak[1]}/s",
                              "if the agent edits one of these files, code_context can give stale results for it; see the overlap check below"))

    # Other warnings and errors, by kind.
    kinds = collections.Counter()
    for l in lines:
        if WATCHER in l:
            continue
        m = AGENT_LOG.match(l)
        if m and m.group(2) in ("warning", "error", "critical", "notice"):
            msg = FIELD_RE.sub("", m.group(4))
            kinds[f"{m.group(2)} {m.group(3)}: {re.sub(r'[0-9]+', 'N', msg).strip()[:120]}"] += 1
        elif re.search(r"\b(warning|error|traceback|exception|killed|refused)\b|TOO SLOW|EMPTY patch|NO ENVIRONMENT", l, re.I):
            kinds[re.sub(r"\d+", "N", FIELD_RE.sub("", l))[:140].strip()] += 1
    print(f"  other warning/error kinds (count, rate per hour over {span_h:.2f} h):")
    for k, n in kinds.most_common(25):
        print(f"   {n:5} {n / span_h:7.1f}/h  {k}")
    if not kinds:
        print("   (none)")
    for k, n in kinds.items():
        if re.search(r"Traceback|\bERROR\b|critical|error ", k):
            R["problems"].append((70, f"log errors: {n} x", k))

    # ACP: version notice and JSON-RPC errors in the log.
    acp = [l for l in lines if "acp.protocol_version" in l or "protocol version" in l.lower()]
    rpc = [l for l in lines if re.search(r"json-?rpc|\"error\"\s*:|refus", l, re.I) and WATCHER not in l]
    print(f"  ACP version lines: {len(acp)}; JSON-RPC error lines: {len(rpc)}")
    for l in acp[:3] + rpc[:3]:
        print(f"   {l[:220]}")
    for l in acp:
        f = dict(FIELD_RE.findall(l))
        req, ans = f.get("acp.protocol_version.requested"), f.get("acp.protocol_version.answered")
        if req and ans and req != ans:
            R["problems"].append((80, f"ACP version fallback: client asked v{req}, agent answered v{ans}", l[:200]))
    if rpc:
        R["problems"].append((75, f"{len(rpc)} JSON-RPC error lines in the run log", rpc[0][:200]))


# ---------------------------------------------------------------- preds and record

def patch_files(patch):
    return set(re.findall(r"^diff --git a/(\S+) ", patch or "", re.M))


def scan_preds(preds, runs, R):
    print(f"== predictions {preds or '(none)'}")
    rows = read_jsonl(preds) if preds and os.path.exists(preds) else []
    if preds and not os.path.exists(preds):
        note(f"missing {preds}")
    empty = [r.get("instance_id") for r in rows if not (r.get("model_patch") or "").strip()]
    edited = set()
    for r in rows:
        edited |= patch_files(r.get("model_patch"))
    print(f"  rows={len(rows)} empty patches={len(empty)} {empty[:10]}")
    R["preds_rows"], R["empty"] = len(rows), empty
    if empty:
        R["problems"].append((65, f"{len(empty)} empty patch(es)", ", ".join(empty[:8])))
    both = edited & R.get("watcher_files", set())
    if R.get("watcher_files"):
        print(f"  patched files that also got the watcher warning: {len(both)} {sorted(both)[:8]}")
        if both:
            R["problems"].append((85, f"{len(both)} patched file(s) got the watcher warning; code_context can be stale for them",
                                  ", ".join(sorted(both)[:6])))
    print(f"== record {runs or '(none)'}")
    rec = read_jsonl(runs) if runs and os.path.exists(runs) else []
    if runs and not os.path.exists(runs):
        note(f"missing {runs}")
    R["record"] = rec
    if not rec:
        return
    stops = collections.Counter(r.get("stop_reason") for r in rec)
    tout = [r.get("instance_id") for r in rec if r.get("timed_out")]
    env = collections.Counter(r.get("env_status") for r in rec)
    print(f"  rows={len(rec)} stop_reason={dict(stops)} env_status={dict(env)}")
    print(f"  timed out: {len(tout)} {tout[:10]}")
    for r in rec:
        print(f"   {r.get('instance_id'):34} seconds={r.get('seconds')} agent={r.get('agent_seconds')} "
              f"stop={r.get('stop_reason')} patch_bytes={r.get('patch_bytes')} timed_out={r.get('timed_out')}")
    if tout:
        R["problems"].append((68, f"{len(tout)} instance(s) hit the --timeout limit", ", ".join(tout[:8])))
    odd = [r.get("instance_id") for r in rec if str(r.get("stop_reason") or "").startswith("_")]
    if odd:
        R["problems"].append((50, f"{len(odd)} instance(s) stopped by a recovery stop reason (_truncated, _repeated, ...)",
                              ", ".join(odd[:8])))


# ---------------------------------------------------------------- transcripts

def detail_of(entry):
    det = []
    for s in (entry or {}).get("segments", []) or []:
        c = s.get("contentJSON") or s.get("content") or s.get("text") or ""
        try:
            cj = json.loads(c)
            det.append(cj.get("detail", c) if isinstance(cj, dict) else c)
        except (TypeError, ValueError):
            det.append(c)
    return "\n".join(str(d) for d in det)


def content_of(row):
    """Give the text that the model got for a tool call: the segment content, else the line text."""
    segs = ((row.get("entry") or {}).get("segments")) or []
    parts = [s.get("content") or s.get("text") or "" for s in segs if isinstance(s, dict)]
    return "\n".join(p for p in parts if p) or row.get("text", "") or ""


def structured_error(j, depth=0):
    """Give the error class of a JSON result from its keys only, or None.

    Look at the keys "error", "isError", "status", "statusCode" and
    "correction". Do not look at the text values: a file or a grep result
    can contain the words "Error" or "failed" as data.
    """
    if depth > 4:
        return None
    if isinstance(j, dict):
        if j.get("error") not in (None, "", False, {}, []):
            return "error field"
        if j.get("isError") is True:
            return "error field"
        for key in ("status", "statusCode"):
            st = j.get(key)
            if isinstance(st, int) and not isinstance(st, bool) and st >= 400:
                return f"{key} {st}"
            if isinstance(st, str) and st.strip().lower() in FAIL_STATUS:
                return f"{key} {st}"
        if j.get("correction") and not j.get("results"):
            return "correction, no results"
        kids = list(j.values())
    elif isinstance(j, list):
        kids = j[:50]
    else:
        return None
    for v in kids:
        if isinstance(v, (dict, list)):
            e = structured_error(v, depth + 1)
            if e:
                return e
    return None


def runcode_error(detail):
    """Give the error class of a runCode result, or None.

    A runCode result is an error only in these conditions:
      - the snippet failed ("The snippet failed: ..."),
      - a tools.* verb is not a function,
      - a tool argument is not valid,
      - a JSON key tells of a failure (see structured_error).
    The words TypeError, Error or failed in the text of a file or in grep
    output do not make an error.
    """
    t = (detail or "").lstrip()
    if t.startswith(SNIPPET_FAIL):
        if NOT_FN_RE.search(t):
            return "is not a function"
        if ARG_FAIL_RE.search(t):
            return "argument validation"
        return "snippet failed"
    if not t.startswith(("{", "[", '"')):
        if NOT_FN_RE.search(t[:300]):
            return "is not a function"
        if ARG_FAIL_RE.search(t[:300]):
            return "argument validation"
        return None
    try:
        j = json.loads(t)
    except ValueError:
        return None
    if isinstance(j, str):
        # The result is a JSON string. It can hold JSON again; read the keys of that only.
        try:
            j = json.loads(j)
        except ValueError:
            return None
    return structured_error(j)


def error_verbs(detail, verbs):
    """Give the verbs that a runCode error counts for.

    The verb that the error names (in "is not a function", or the tool name
    in an argument error), else each verb of the snippet. An error with no
    verb in the snippet counts for "runCode(no tools verb)".
    """
    m = NOT_FN_RE.search(detail or "")
    if m:
        return [m.group(1)[len("tools."):]]
    a = re.search(r'Tool "([A-Za-z_]+)" argument', detail or "")
    if a:
        hit = sorted({v for v in verbs if v.split(".", 1)[1] == a.group(1)})
        if hit:
            return hit[:1]
    return sorted(set(verbs)) or ["runCode(no tools verb)"]


def execute_result(status, detail):
    """Sort one execute (shell) result. Give (sort, reason).

    sort is "ok", "nonzero" or "failure". A nonzero exitCode is normal work
    (a failed test, a script that stops), not a tool failure. A failure is a
    command that the tool could not run to its end: a timeout, a command that
    could not start, or an error key.
    """
    try:
        j = json.loads(detail)
    except (TypeError, ValueError):
        j = None
    if isinstance(j, dict):
        st = str(j.get("status", "")).strip().lower()
        if j.get("timedOut") is True or st in FAIL_STATUS or j.get("error") not in (None, "", False, {}, []):
            return "failure", f"status {st or '?'}" if st in FAIL_STATUS else "error key or timeout"
        ec = j.get("exitCode")
        if isinstance(ec, int) and not isinstance(ec, bool):
            return ("ok", "") if ec == 0 else ("nonzero", f"exitCode {ec}")
    if status == "failed":
        return "failure", "status failed"
    if re.search(r"timed out|could not start|cannot start|failed to (start|launch|spawn)", (detail or "")[:300], re.I):
        return "failure", "could not run"
    return "ok", ""


def find_live_transcripts():
    """Find the transcripts dir of the clone that the live agent uses."""
    out = []
    for pid in sh("pgrep -f 'acp-agent acp'").split():
        cwd = ""
        for l in sh(f"lsof -a -p {pid} -d cwd -Fn").splitlines():
            if l.startswith("n"):
                cwd = l[1:]
        for d in (os.path.join(cwd, "repo", ".acp-agent", "transcripts"), os.path.join(cwd, ".acp-agent", "transcripts")):
            if cwd and os.path.isdir(d):
                out.append(d)
    return out


def instance_of(path):
    """The instance id of a kept transcript, or "clone" for a transcript in a clone."""
    m = re.search(r"\.transcripts/([^/]+)/", path)
    return m.group(1) if m else "clone"


def add_sample(T, key, text):
    if len(T["samples"][key]) < 2:
        T["samples"][key].append(text)


def scan_transcripts(dirs, gap_s, R):
    files = []
    for d in dirs:
        if not os.path.exists(d):
            note(f"missing {d}")
            continue
        files += sorted(glob.glob(os.path.join(d, "**", "transcript.jsonl"), recursive=True))
    print(f"== transcripts: {len(files)} file(s)")
    T = R["tools"]
    now = dt.datetime.now(dt.timezone.utc)
    for f in files:
        rows = read_jsonl(f)
        inst = instance_of(f)
        print(f"-- {inst}: {f}  lines={len(rows)}")
        seqs = sorted({r.get("seq") for r in rows if isinstance(r.get("seq"), int)})
        missing = [s for s in range(seqs[0], seqs[-1] + 1) if s not in set(seqs)] if seqs else []
        if missing:
            # The seq numbers are shared with the tool-selection sessions of the
            # router (see the recordings). A gap is thus not always a lost line.
            print(f"   missing seq numbers: {missing[:30]}{' ...' if len(missing) > 30 else ''}")
            T["seq_missing"] += len(missing)
        rows_t = sorted((r for r in rows if r.get("ts")), key=lambda r: r["ts"])
        if rows_t:
            a, b = ts(rows_t[0]["ts"]), ts(rows_t[-1]["ts"])
            idle = (now - b).total_seconds()
            print(f"   span {a:%H:%M:%S}Z .. {b:%H:%M:%S}Z = {(b - a).total_seconds():.0f}s; last line {idle:.0f}s ago")
            if R.get("live_dirs") and any(f.startswith(d) for d in R["live_dirs"]) and idle > max(gap_s, 300):
                R["problems"].append((72, f"live transcript has no new line for {idle:.0f}s", f))
        for r0, r1 in zip(rows_t, rows_t[1:]):
            g = r1["ts"] - r0["ts"]
            if g < gap_s:
                continue
            # The same stall can show two times, before two lines with near seq
            # numbers. Report it one time.
            seq = r1.get("seq") if isinstance(r1.get("seq"), int) else -1
            if any(s[1] == inst and abs(s[0] - g) < 2 and abs((s[2] if isinstance(s[2], int) else -1) - seq) <= 20
                   for s in T["stalls"]):
                continue
            tok = r1.get("tokensOut")
            print(f"   stall {g:.0f}s before seq {r1.get('seq')} ({r1.get('kind')}"
                  f"{', ' + str(tok) + ' tokens out' if tok is not None else ''}) at {ts(r1['ts']):%H:%M:%S}Z")
            T["stalls"].append((g, inst, r1.get("seq"), tok))

        # The tool calls of the model: call id -> (tool name, arguments).
        # The runCode arguments keep the code of the snippet.
        calls = {}
        # The final operation events: correlation id -> detail. A runCode
        # result that is still pending gets its final detail from here.
        ops = {}
        for r in rows:
            if r.get("kind") == "toolCalls":
                for c in (r.get("entry") or {}).get("toolCalls") or []:
                    try:
                        args = json.loads(c.get("argumentsJSON") or "{}")
                    except (TypeError, ValueError):
                        args = {}
                    calls[c.get("id")] = (c.get("toolName"), args if isinstance(args, dict) else {})
            elif r.get("kind") == "toolOutput":
                m = STATUS_RE.match(r.get("text", "") or "")
                if m and m.group(4) != "running":
                    ops[m.group(3)] = detail_of(r.get("entry")) or r.get("text", "")

        last_err = {}  # group -> the made-up verb, for the recovery check
        for r in sorted(rows, key=lambda r: r.get("seq") if isinstance(r.get("seq"), int) else -1):
            kind = r.get("kind")
            T["kinds"][kind] += 1
            if kind == "generationCall":
                T["gen"] += 1
                T["tokens_out"] += r.get("tokensOut", 0) or 0
                continue
            if kind == "instructions":
                T["instructions"] += 1
                for m in VERB_RE.finditer(r.get("text", "")):
                    T["offered"][".".join(m.groups())] += 1
                continue
            if kind != "toolOutput":
                continue
            e = r.get("entry", {}) or {}
            tool = e.get("toolName") or "?"
            cid = str(e.get("entryId") or "")
            where = f"{inst} seq {r.get('seq')}"
            if cid not in calls and not cid.startswith("call_"):
                # An operation event: "[tool] op (ULID) running|completed|failed: ...".
                # The model gets the runCode result in its own toolOutput line
                # (see below), so count only the execute (shell) results here.
                m = STATUS_RE.match(r.get("text", "") or "")
                status = m.group(4) if m else "other"
                if status == "running":
                    T["running_notices"] += 1
                    continue
                if tool != "execute":
                    continue
                det = detail_of(e) or r.get("text", "")
                T["tool"][tool] += 1
                T["per_inst"][inst] += 1
                sort, why = execute_result(status, det)
                if sort == "nonzero":
                    T["exec_nonzero"] += 1
                    if len(T["nonzero_samples"]) < 2:
                        T["nonzero_samples"].append(f"{where}: {det[:160]!r}")
                elif sort == "failure":
                    T["tool_err"][tool] += 1
                    add_sample(T, f"execute: {why}", f"{where}: {det[:200]!r}")
                elif "shell" in last_err:
                    # The execute tool and tools.shell.* are the same group.
                    T["recovered"][last_err.pop("shell")] += 1
                continue

            # The result of one tool call of the model. Pair it with its call by the id.
            name, args = calls.get(cid, (tool, {}))
            tool = tool if tool != "?" else (name or "?")
            text = content_of(r)
            T["tool"][tool] += 1
            T["per_inst"][inst] += 1
            if tool == "skills":
                n = args.get("id") or args.get("name")
                if not n:
                    m = re.search(r"use skill\W+([\w:-]+)", text)
                    n = m.group(1) if m else "?"
                T["skills"][n] += 1
                continue
            if tool != "runCode":
                continue
            try:
                c = json.loads(text)
            except ValueError:
                c = None
            detail = text
            outcome = None
            if isinstance(c, dict) and "completionToken" in c:
                outcome = c.get("outcome")
                detail = c.get("detail")
                if c.get("pending"):
                    detail = ops.get(c.get("completionToken"))
                    if detail is None:
                        T["pending"] += 1
                        detail = ""
            if not isinstance(detail, str):
                detail = json.dumps(detail)
            code = args.get("code") or ""
            if cid not in calls:
                T["no_code"] += 1
            verbs = [".".join(v) for v in VERB_RE.findall(code)]
            for v in verbs:
                T["verb"][v] += 1
                if v.startswith("web."):
                    T["web"][v] += 1
            if not verbs:
                T["verb"]["runCode(no tools verb)" if cid in calls else "runCode(call not in transcript)"] += 1
            groups = {v.split(".")[0] for v in verbs}
            if "code_context" in groups:
                T["code_context"] += 1
            up = UPSTREAM_RE.search(detail)
            if up and "web" in groups:
                T["upstream"].append(f"{where}: {up.group(0)[:70]}")
            if "files.grep" in verbs and ".acp-agent/transcripts" in detail.replace("\\/", "/"):
                T["self_grep"].append(where)
            cls = runcode_error(detail) or ("outcome failed" if outcome == "failed" else None)
            if cls:
                T["tool_err"][tool] += 1
                for v in error_verbs(detail, verbs):
                    T["verb_err"][v] += 1
                add_sample(T, cls, f"{where}: {detail[:200]!r}")
            if cls == "is not a function":
                nf = NOT_FN_RE.search(detail)
                full = nf.group(1)
                T["made_up"][full] += 1
                hint = re.search(r"Call (tools\.[a-z_]+\.[a-zA-Z_]+) instead", detail)
                T["made_up_hint"][full] = hint.group(1) if hint else "?"
                # The evidence of a made-up verb is its own "is not a function" result.
                T["made_up_ev"].setdefault(full, f"{where}: {detail[:200]!r}")
                last_err[full.split(".")[1]] = full
            elif not cls:
                for g in groups:
                    if g in last_err:
                        T["recovered"][last_err.pop(g)] += 1


def report_tools(R):
    T = R["tools"]
    print("== per tool (one result for each call of the model; execute: the shell commands): calls / errors")
    for k, n in T["tool"].most_common():
        print(f"   {k:30} {n:5} / {T['tool_err'][k]}")
    print(f"   execute: nonzero exit (normal work: tests, scripts), not counted as errors: {T['exec_nonzero']}")
    for s in T["nonzero_samples"]:
        print(f"     e.g. {s}")
    print(f"   'running' notices (not counted above): {T['running_notices']}")
    if T["pending"] or T["no_code"]:
        print(f"   runCode results with no final result: {T['pending']}; with no call in the transcript: {T['no_code']}")
    print("== per tools.<group>.<verb> (from the code of each runCode call): calls / errors")
    print("   (an error counts for the verb that it names, else for each verb of the snippet)")
    made = {k[len("tools."):] for k in T["made_up"]}
    for k in sorted(set(T["verb"]) | set(T["verb_err"]), key=lambda k: (-T["verb"][k], k)):
        print(f"   {k + (' (made-up)' if k in made else ''):34} {T['verb'][k]:5} / {T['verb_err'][k]}")
    print("== results per instance: " + ", ".join(f"{k}={n}" for k, n in T["per_inst"].items()))
    print(f"== web: search={T['web']['web.search']} fetch={T['web']['web.fetch']} "
          f"errors={sum(n for k, n in T['verb_err'].items() if k.startswith('web.'))} "
          f"(router chose web.* {sum(n for k, n in R['rec']['chosen'].items() if k.startswith('web.'))} times)")
    print(f"== skills tool: {sum(T['skills'].values())} result(s) {dict(T['skills'])}")
    print(f"== runCode results that use code_context: {T['code_context']}")
    print(f"== 'instructions' lines: transcripts={T['instructions']} recordings={R['rec']['kinds'].get('instructions', 0)}")
    print(f"== generations: {T['gen']}, tokens out {T['tokens_out']}")
    print("== made-up verbs ('is not a function'): " + (", ".join(
        f"{k} x{n} (hint {T['made_up_hint'][k]}; recovered {T['recovered'][k]})" for k, n in T["made_up"].items()) or "none"))
    print(f"== files.grep results with .acp-agent/transcripts lines (self-matches): {len(T['self_grep'])} {T['self_grep'][:6]}")
    print(f"== results that look like the upstream fix (web): {len(T['upstream'])} {T['upstream'][:5]}")
    print("== error samples")
    for k, v in T["samples"].items():
        for s in v:
            print(f"   [{k}] {s}")


# ---------------------------------------------------------------- recordings

def find_recordings(since):
    base = os.environ.get("TMPDIR", "/tmp")
    dirs = glob.glob(os.path.join(base, "acp-agent-recordings-*"))
    dirs = [d for d in dirs if os.path.getmtime(d) >= since]
    return sorted(dirs, key=os.path.getmtime)[-3:]


def scan_recordings(dirs, R):
    print("== recordings (tool-selection model sessions only; no ACP traffic is kept here)")
    rec = R["rec"]
    if not dirs:
        note("no recordings dir")
    for d in dirs:
        if not os.path.exists(d):
            note(f"missing {d}")
            continue
        fs = glob.glob(os.path.join(d, "**", "transcript.jsonl"), recursive=True)
        errs = 0
        pv = set()
        for p in fs:
            for r in read_jsonl(p):
                rec["kinds"][r.get("kind")] += 1
                raw = json.dumps(r)
                errs += len(re.findall(r'"error"\s*:', raw))
                pv |= set(re.findall(r'protocolVersion\\?"\s*:\s*(\d+)', raw))
                if r.get("kind") == "prompt":
                    m = re.search(r"Choose only from these ids: ([^\n]*)", r.get("text", ""))
                    if m:
                        for i in re.findall(r"[a-z_]+\.[a-zA-Z_]+", m.group(1)):
                            rec["offered"][i] += 1
                if r.get("kind") == "response":
                    for i in re.findall(r'\\"ids\\":\s*\[([^\]]*)\]|"ids":\s*\[([^\]]*)\]', raw):
                        for x in re.findall(r"[a-z_]+\.[a-zA-Z_]+", "".join(i)):
                            rec["chosen"][x] += 1
        print(f"  {d}: sessions={len(fs)} error-keys={errs} protocolVersion={sorted(pv) or 'none'}")
    print(f"  kinds {dict(rec['kinds'])}")
    print(f"  verbs the router chose: {dict(rec['chosen'].most_common(20))}")
    web_offered = any(k.startswith("web.") for k in rec["offered"])
    print(f"  web.* in the offered ids: {web_offered}")
    R["web_offered"] = web_offered if rec["offered"] else None


# ---------------------------------------------------------------- score

def scan_score(preds, R):
    """Read the newest score report: <preds>.score.<run id>.json."""
    print("== score")
    if not preds:
        note("no predictions file, so no score report")
        return
    reps = sorted(glob.glob(preds + ".score.*.json"), key=os.path.getmtime)
    if not reps:
        note(f"no {preds}.score.*.json yet; score after the run ends")
        return
    try:
        d = json.load(open(reps[-1]))
    except (OSError, ValueError) as e:
        note(f"cannot read {reps[-1]}: {e}")
        return
    ev, rs = d.get("evaluated"), d.get("resolved")
    print(f"  {reps[-1]}")
    print(f"  submitted={d.get('submitted')} evaluated={ev} resolved={rs} unresolved={d.get('unresolved')} "
          f"errored={d.get('errored') if not isinstance(d.get('errored'), list) else len(d['errored'])}"
          + (f"  score={rs}/{ev}={rs / ev:.1%}" if isinstance(ev, int) and ev and isinstance(rs, int) else ""))
    for k in ("resolved_ids", "unresolved_ids", "errored_ids"):
        if d.get(k):
            print(f"   {k}: {d[k][:20]}")


# ---------------------------------------------------------------- report

def progress(R, timeout):
    print("== PROGRESS")
    started, ended = R.get("started", {}), R.get("ended", {})
    done = [k for k, v in ended.items() if v[1] not in ("skipped",)]
    print(f"  done {len(done)} / {R.get('total') or '?'}; started {len(started)}; "
          f"run {'complete' if R.get('complete') else 'not complete'}")
    now = dt.datetime.now()
    for k, (c, n, of, limit) in started.items():
        if k in ended:
            e = ended[k]
            dur = (e[0] - c).total_seconds() if e[0] and c else None
            print(f"   #{n} {k:34} {e[1]:8} {e[2] or (f'{dur:.0f}' if dur else '?')}s")
        else:
            el = (now - c).total_seconds() if c else 0
            flag = " NEAR THE LIMIT" if el > 0.8 * limit else ""
            print(f"   #{n} {k:34} RUNNING  {el:.0f}s of {limit}s{flag}")
            if flag:
                R["problems"].append((78, f"{k} runs {el:.0f}s of its {limit}s limit", "it will get session/cancel"))


def problems(R):
    T = R["tools"]
    total_results = sum(T["tool"].values())
    if R.get("web_enabled") and total_results >= 20 and not T["web"]:
        config_problem(R, 88, f"web is on in the config, but 0 web calls in {total_results} tool results",
                       f"router chose web.* {sum(n for k, n in R['rec']['chosen'].items() if k.startswith('web.'))} times;"
                       f" web.* offered to the router: {R.get('web_offered')}")
    if R.get("web_enabled") and R.get("web_offered") is False:
        config_problem(R, 89, "web is on in the config, but the tool-selection model was not offered web.*",
                       "no web.* id in 'Choose only from these ids' of the recordings: the agent did not mount tools.web")
    if R.get("web_enabled") is False:
        config_problem(R, 90, "web is OFF in the config", "tools.web.enabled: false")
    for k, n in T["made_up"].items():
        R["problems"].append((62, f"made-up verb {k} x{n}; correct verb {T['made_up_hint'][k]}; recovered {T['recovered'][k]} time(s)",
                              T["made_up_ev"].get(k, "")[:220]))
    if T["upstream"]:
        R["problems"].append((86, f"the agent got what looks like the upstream fix from the web ({len(T['upstream'])} result(s))",
                              f"{T['upstream'][:3]}; the score of this run does not measure the agent alone"))
    if T["web"] and T["verb_err"]["web.search"] >= T["web"]["web.search"] > 0:
        R["problems"].append((76, f"every web.search failed ({T['verb_err']['web.search']} of {T['web']['web.search']})",
                              (T["samples"].get("correction, no results") or [""])[0][:200]))
    if T["self_grep"]:
        R["problems"].append((58, f"{len(T['self_grep'])} files.grep result(s) match the agent's own .acp-agent/transcripts",
                              f"{T['self_grep'][:4]}; .acp-agent has no ignore rule in the clone"))
    for g, inst, seq, tok in sorted(T["stalls"], reverse=True)[:3]:
        R["problems"].append((45 + min(int(g / 60), 20), f"generation stall {g:.0f}s in {inst} before seq {seq}",
                              f"{tok} tokens out" if tok is not None else "no token count"))
    errs = sum(T["tool_err"].values())
    if total_results and errs / total_results > 0.15:
        R["problems"].append((60, f"tool error rate {errs}/{total_results}", str(dict(T['verb_err']))))
    print("== PROBLEMS (ranked; higher first)")
    if not R["problems"]:
        print("   none found")
    seen = set()
    rank = 0
    for score, what, ev in sorted(R["problems"], key=lambda p: -p[0]):
        if what in seen:
            continue
        seen.add(what)
        rank += 1
        print(f"  {rank}. [{score}] {what}\n       evidence: {ev}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", help="the output name: sets bench/run.NAME.log, bench/preds.NAME.jsonl, "
                                   "bench/preds.NAME.runs.jsonl, bench/preds.NAME.transcripts and bench/NAME.config.yaml")
    ap.add_argument("--bench", default="bench", help="the bench dir (default: bench)")
    ap.add_argument("--log")
    ap.add_argument("--preds")
    ap.add_argument("--runs")
    ap.add_argument("--config")
    ap.add_argument("--transcripts", nargs="*", default=[])
    ap.add_argument("--recordings", nargs="*", default=None,
                    help="default: the newest $TMPDIR/acp-agent-recordings-* dirs that changed after the log started")
    ap.add_argument("--live", action="store_true", help="also read the transcripts of the clone that the agent uses now")
    ap.add_argument("--timeout", type=int, default=3000, help="the --timeout of the run (default 3000)")
    ap.add_argument("--gap", type=float, default=60, help="a gap of this many seconds is a stall (default 60)")
    a = ap.parse_args()
    b = a.bench
    if a.name:
        a.log = a.log or os.path.join(b, f"run.{a.name}.log")
        a.preds = a.preds or os.path.join(b, f"preds.{a.name}.jsonl")
        a.runs = a.runs or os.path.join(b, f"preds.{a.name}.runs.jsonl")
        a.transcripts = a.transcripts or [os.path.join(b, f"preds.{a.name}.transcripts")]
        cfg = os.path.join(b, f"{a.name}.config.yaml")
        a.config = a.config or (cfg if os.path.exists(cfg) else None)
    if a.preds and not a.runs and a.preds.endswith(".jsonl"):
        a.runs = a.preds[:-len(".jsonl")] + ".runs.jsonl"
    if a.live:
        live = find_live_transcripts()
        print(f"== live transcripts: {live or 'none (no live agent, or no transcript yet)'}")
        a.transcripts = list(a.transcripts) + live
        R_live = live
    else:
        R_live = []

    R = {"problems": [], "rec": {"kinds": collections.Counter(), "chosen": collections.Counter(),
                                  "offered": collections.Counter()},
         "tools": {"tool": collections.Counter(), "tool_err": collections.Counter(), "verb": collections.Counter(),
                   "verb_err": collections.Counter(), "samples": collections.defaultdict(list),
                   "kinds": collections.Counter(), "per_inst": collections.Counter(), "web": collections.Counter(),
                   "skills": collections.Counter(), "offered": collections.Counter(), "made_up": collections.Counter(),
                   "made_up_hint": {}, "made_up_ev": {}, "recovered": collections.Counter(), "self_grep": [],
                   "stalls": [], "upstream": [], "nonzero_samples": [], "running_notices": 0, "code_context": 0,
                   "instructions": 0, "gen": 0, "tokens_out": 0, "seq_missing": 0, "exec_nonzero": 0,
                   "pending": 0, "no_code": 0}}
    R["live_dirs"] = R_live
    print(f"swebench scan at {dt.datetime.now():%Y-%m-%d %H:%M:%S}")
    start = run_start(a.log)
    steps = [lambda: scan_config(a.config, R, start), lambda: scan_log(a.log, a.timeout, R),
             lambda: scan_preds(a.preds, a.runs, R), lambda: scan_transcripts(a.transcripts, a.gap, R),
             lambda: scan_recordings(a.recordings if a.recordings is not None
                                     else find_recordings(R.get("start_epoch", time.time() - 6 * 3600)), R),
             lambda: scan_score(a.preds, R), lambda: report_tools(R), lambda: progress(R, a.timeout),
             lambda: problems(R)]
    for step in steps:
        try:
            step()
        except Exception as e:  # One bad step must not stop the scan.
            note(f"a scan step failed: {type(e).__name__}: {e}")


if __name__ == "__main__":
    sys.exit(main())
