---
name: swebench-score
description: Score a finished SWE-bench run of this ACP agent with docker, and report the result. Takes one argument - a run NAME (bench/preds.NAME.jsonl), a predictions path, or nothing (the newest bench/preds.*.jsonl that has no score report). Use when the user says "score the bench", "swebench score", "score the run", "how did the run score", "what did the bench resolve", "compare bench runs", or "compare the scores". Checks docker and disk, starts a detached score run, watches it, gives a table for each instance with the web and upstream-fix flags, and compares with the score of an other run.
license: MIT OR Apache-2.0
compatibility: macOS. Needs docker (Docker Desktop), uv and python3. Reads bench/ and logs/run_evaluation/ of this package.
metadata:
  author: swissarmyhammer
  version: 0.1.0
---

# swebench-score

Score a finished SWE-bench run of `acp-agent`, and report the result.

For the basics of the score step (the command, the flags, the exit codes, the
fields of the score report), read `bench/README.md` ("The score"). This skill
does not repeat them. To make the patches and to watch the agent, use the
`swebench` skill (`.claude/skills/swebench/SKILL.md`).

**Rules**

- Do not stop, start or change a score run that you did not start in this
  session.
- Do not score a predictions file while `swebench_run.py` writes to it.
- Do not edit the harness (`bench/*.py`) to do this work.
- Run each shell command so that it exits quickly. For the score run, use a
  detached start (step 2) and a Monitor (step 3).
- A Monitor stops after 30 minutes at most, and each process that the
  Monitor command starts stops with it. So start the score with `nohup ... &`
  in a usual shell call (step 2). A Monitor only waits and watches. Do not
  start the score at the end of a wait loop in a Monitor.
- A wait loop must not find its own command line. Write the process pattern
  with a bracket, for example `pgrep -f '[s]webench_score\.py bench/preds\.NAME\.jsonl'`.
  The regex `[s]` finds the letter `s`, but the text `[s]` of the command line
  is not `s`, so the pattern cannot find the shell that holds it. Also do not
  put a background subshell (`( ... ) &`) in a wait-loop command: on macOS
  `pgrep` does not find its own ancestors, but that subshell is a sibling, and
  it holds the full command text.
- Do not remove docker images unless the user asks (step 6).
- Write all notes and reports in ASD-STE100 Simplified Technical English.

## The argument

| Argument | The predictions file |
|---|---|
| a NAME, for example `code-context` | `bench/preds.NAME.jsonl` |
| a path, for example `bench/preds.x.jsonl` | that path; NAME is the part between `preds.` and `.jsonl` |
| nothing | the newest `bench/preds.*.jsonl` that has no score report |

For "nothing", use this command. A `.runs.jsonl` file is a record, not a
predictions file:

```bash
ls -t bench/preds.*.jsonl | grep -v '\.runs\.jsonl$' | while read -r p; do
  ls "$p".score.*.json >/dev/null 2>&1 || { echo "$p"; break; }; done
```

If a score report exists already and the user only wants the result, go to
step 4. To score again, use a new `--run-id` (step 2).

## 1. Preflight

Do these checks first. Stop and tell the user if one fails.

1. **Docker.** When the disk is full, or when Docker Desktop pauses its VM,
   `docker info` hangs and does not fail. So always use a time limit:

   ```bash
   timeout 10 docker info >/dev/null 2>&1; echo "docker info exit $?"
   df -h ~
   ```

   `timeout` is in GNU coreutils (`brew install coreutils`); it is not in
   macOS. Exit 0: docker is up. Exit 124: docker did not answer in 10 seconds.
   Another exit: docker is down. On macOS, Docker Desktop is
   `/Applications/Docker.app`, its socket is `~/.docker/run/docker.sock`, and
   its VM disk is in `~/Library/Containers/com.docker.docker`, so `df -h ~`
   shows the free space that it can use. `swebench_score.py` sets
   `DOCKER_HOST` to that socket itself.

   - **Exit 124 (hung).** Stop, and tell the user: "Docker Desktop does not
     answer. Restart Docker Desktop (Docker menu > Restart)." Give the free
     space of `df -h ~`. With less than 30 GB free, also tell the user to get
     space back first (step 6).
   - **Down.** Start it, and wait up to 4 minutes:

     ```bash
     open -a Docker
     for i in $(seq 1 16); do timeout 10 docker info >/dev/null 2>&1 && break; sleep 5; done
     timeout 10 docker info >/dev/null 2>&1 && echo up || echo "still down after 4 min"
     ```

     Run the wait loop in a Monitor (timeout 300000 ms), because it is longer
     than a usual tool call. If docker is still down, stop, give the free space
     of `df -h ~`, and tell the user to restart Docker Desktop.

   Give docker 16 GB of memory or more on Apple Silicon (Docker Desktop >
   Settings > Resources); `timeout 10 docker info --format '{{.MemTotal}}'`
   shows it.
2. **Disk.** `df -h ~` and `timeout 30 docker system df`. The harness pulls the
   published x86_64 image of each instance (`swebench/sweb.eval.x86_64.*`),
   and docker runs it with emulation. Each instance can need several GB. Have 50 GB free
   or more for a run of about 16 instances. With less than 30 GB free, stop and
   tell the user (step 6 tells how to get space back).
3. **The run is done.** The run log has `complete`, and no harness process
   writes the predictions:

   ```bash
   ps -axo pid,etime,command | grep -E '[s]webench_run\.py'
   ```

4. **No collision.** No other score run uses the same predictions:

   ```bash
   ps -axo pid,etime,command | grep -E '[s]webench_score\.py'
   ```

   The `[s]` keeps the shell of this command out of the result. If a live
   score run names the same predictions path, do not start. Watch
   it (step 3) in place of a new run. If an old `bench/score.NAME.log` exists,
   move it: `mv bench/score.NAME.log bench/score.NAME.log.old-$(date +%H%M)`.

## 2. Start detached

Start the score run detached, in a usual shell call, so that it survives a
tool timeout and the end of a Monitor. Never put this command in a Monitor:

```bash
nohup sh -c 'uv run bench/swebench_score.py bench/preds.NAME.jsonl 2>&1 | tee bench/score.NAME.log' >/dev/null 2>&1 &
```

Add flags inside the quotes when necessary:

- `--instance-ids ID ...` scores some ids only.
- `--max-workers N`: keep the default of 1. Parallel emulated x86_64
  containers use much memory, and docker can stop them (exit 137).
- `--run-id NAME` to score again. Each run id gives a new report
  (`preds.NAME.jsonl.score.<run id>.json`), and the old report stays.
- `--no-retry-errors` does not do an instance that did not run again.

Wait about 1 minute. Then read the log. It must have
`the instances of this score run` with `run_id=...`. Keep the run id: the
harness writes the logs of each instance to
`logs/run_evaluation/<run id>/acp-agent/<instance id>/` (`run_instance.log`,
`test_output.txt`, `patch.diff`, and `report.json` when the tests ran). If the log has
`docker does not answer`, the run stopped with exit 3: go back to step 1.

The first pass pulls the images, and it is slow: one hour or more for 16
instances.

## 3. Watch

Arm a Monitor (30 minutes, the maximum). Re-arm it each time it expires. The
command shows the new lines of the log and each new `report.json` every 30
seconds, and it ends when no `swebench_score.py` process for NAME is left.
The Monitor only waits: the score process of step 2 does not stop when the
Monitor stops. Put NAME and the run id of step 2 in the first line:

```bash
NAME=code-context; RUN=score_YYYYMMDD_HHMMSS; LOG=bench/score.$NAME.log
n=$(( $(wc -l < "$LOG") )); seen=""
show() {
  m=$(( $(wc -l < "$LOG") ))
  [ "$m" -gt "$n" ] && sed -n "$((n + 1)),${m}p" "$LOG" | tr '\r' '\n' | grep -E \
    'did not run|did NOT run|harness call failed|docker failed|Error|error building|Traceback|Killed|137|docker does not answer|no instance was evaluated|nothing to score|the score:|score complete|the report of this score run'
  n=$m
  for f in $(find "logs/run_evaluation/$RUN" -name report.json 2>/dev/null); do
    case "$seen" in *"$f"*) continue;; esac
    seen="$seen $f"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); k=next(iter(d)); print("instance", k, "RESOLVED" if d[k].get("resolved") else "unresolved")' "$f"
  done
}
while pgrep -f "[s]webench_score\.py bench/preds\.$NAME\.jsonl" >/dev/null; do show; sleep 30; done
show; echo "no swebench_score.py process for $NAME is left"
```

The harness writes no line for a resolved instance, so the loop reads each
new `report.json`. An instance with no `report.json` did not run its tests.
When the command ends, read the exit messages at the end of the log. If the
log has no `score complete` and no `no instance was evaluated`, the score
stopped in the middle: resume it (below). If the pattern finds no process at
the start, the command ends at once; then check the command line with
`ps -axo pid,etime,command | grep -E '[s]webench_score\.py'`.

### Resume a score that stopped

A score can stop in the middle, for example when docker hangs or the machine
sleeps. Do not start again from the start. Each instance that ran has its
`report.json` in `logs/run_evaluation/<run id>/`, and `tally()` of
`swebench_score.py` reads each `report.json` in that dir. So run
`swebench_score.py` again with the same `--run-id`, and with
`--instance-ids` for only the missing instances. The result then includes all
instances.

1. Do the preflight again (step 1). Make sure that no `swebench_score.py`
   process for NAME is left (step 1, item 4).
2. Find the run id in the log (`run_id=...`), and the missing instances:

   ```bash
   NAME=code-context; RUN=score_YYYYMMDD_HHMMSS
   python3 -c 'import json,os,sys; run, preds = sys.argv[1:]; ids = [json.loads(l)["instance_id"] for l in open(preds) if l.strip()]; print(" ".join(i for i in ids if not os.path.exists(f"logs/run_evaluation/{run}/acp-agent/{i}/report.json")))' "$RUN" "bench/preds.$NAME.jsonl"
   ```

   An empty line tells that each instance has a `report.json`. Then do not
   resume; the run only stopped before it wrote the score report. Run step 2
   with the same `--run-id` and with no `--instance-ids`: the harness finds
   each report, runs no instance again, and writes the score report.
3. Move the old log (`mv bench/score.NAME.log bench/score.NAME.log.stopped-$(date +%H%M)`),
   and start the resume detached, in a usual shell call, with the ids of item 2:

   ```bash
   nohup sh -c 'uv run bench/swebench_score.py bench/preds.NAME.jsonl --run-id RUN --instance-ids ID1 ID2 ... 2>&1 | tee bench/score.NAME.log' >/dev/null 2>&1 &
   ```

4. Watch it (step 3) with the same `RUN`.

The resolved and evaluated counts of the new score report include all
instances of the run id. `submitted` counts each prediction of the file, and
not only the ids of `--instance-ids`. So `resolved / submitted` is correct for
a resumed score too. But the `errored` group holds only the ids of
`--instance-ids` that did not run. An instance of an earlier pass that did not
run is not in that group; compare `submitted` with `evaluated` to find it.
Tell the user that the score was resumed.

## 4. Report

```bash
python3 .claude/skills/swebench-score/scripts/report.py NAME
```

Other forms: `--score FILE.json` (a report that is not the newest),
`--scan FILE` (a saved output of `scan.py` of the swebench skill; its
upstream-fix items are added), `--compare NAME|FILE`, `--no-compare`,
`--root DIR` (the dir where the harness wrote `logs/`). With no argument, the
script uses the newest predictions file that has a score report.

Each path must resolve to a place inside the repo root (the dir that holds
`bench/`). For a path on the command line outside the repo root, the script
stops with exit code 2. Thus save a `scan.py` output below the repo, not in
`/tmp`. For a path from a run file (the `agent_config` of the record or the
run log, a score file name, a transcript, a harness log dir) outside the repo
root, the script writes a note to stderr and does not read that path.

The script reads the score report, the predictions, the record
(`preds.NAME.runs.jsonl`), the kept transcripts, the harness logs and the
agent config. It gives:

- **SCORE**: resolved / evaluated (the honest score), resolved / submitted,
  and resolved / not empty.
- **INSTANCES**: one row for each instance: the result (`RESOLVED`, `no`,
  `EMPTY`, `NOT RUN`), the patch size, the seconds, the stop reason, web
  used (y/n with the count of web calls), and `YES` when a web result looks
  like the upstream fix.
- **NOT RUN**: the harness errors (the image did not pull, the patch did not
  apply, the tests timed out), apart from the unresolved instances. These are
  not agent failures. The harness does not send an empty patch to docker, so
  `errored_ids` of the score report holds the empty patches too. The script
  shows them apart.
- **UNRESOLVED**: the `FAIL_TO_PASS` and `PASS_TO_PASS` counts of each
  unresolved instance.
- **WEB**: the web state and the path of the config of the run, and a warning
  when web was on. The script finds the config in this order: the
  `agent_config` field of the record, the `agent_config=PATH` or
  `--agent-config PATH` text in the head of `bench/run.NAME.log`, and
  `bench/NAME.config.yaml`. When it finds none, the state is `unknown`. A web
  search can find the upstream fix of the issue. The script finds it with the
  same pattern and the same transcript pairing as `scan.py` of the swebench
  skill (it loads that script as a module). For a full check, also run
  `python3 .claude/skills/swebench/scripts/scan.py --name NAME`.

Give the user the SCORE lines, the table, the harness errors, and the web
warning. Do not compare a run with web on to a run with web off as if they
measure the same thing.

## 5. Compare

With no `--compare`, the script compares with the newest other run whose
predictions file has the same instance ids, and a score older than this score
comes first. A run with other instances does not measure the same thing, so the
script never takes it; when no run has the same ids, it says so and compares
with nothing. The COMPARE section says which run the script took, and why.
`--compare NAME` (or a score json, which can also be an other run id of the same
predictions) names the run, also a run with other instances. For each
instance it gives the result before, the result now, and the delta:
`fixed` (now resolved, before not), `broken` (before resolved, now not),
`same`, or `only one run`. Use it to measure a change of the agent, for
example a Multitool fix: score the run before and the run after with the same
instances, and report the fixed and broken ids. The script gives a warning when
the web state of the two runs is not the same.

## 6. Cleanup (only when the user asks)

The images stay after a score run, and a new score of the same instances is
faster with them. Remove them only when the user asks:

```bash
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep 'sweb\.'    # show them
docker rmi $(docker images -q --filter 'reference=swebench/sweb.eval.*')       # pulled instance images
docker rmi $(docker images -q --filter 'reference=sweb.eval.*')                # instance images
docker rmi $(docker images -q --filter 'reference=sweb.env.*')                 # environment images
docker rmi $(docker images -q --filter 'reference=sweb.base.*')                # base images
docker builder prune -f                                                         # the build cache
```

Remove the instance images first; an environment image can be the base of
an instance image. The harness also writes `logs/run_evaluation/<run id>/`,
`logs/build_images/`, and a run report `acp-agent.<run id>.json` in the root
of the package. Remove them only when the user asks, and keep the score report
in `bench/`.
