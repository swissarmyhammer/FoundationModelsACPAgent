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

1. **Docker.** `docker info >/dev/null 2>&1 && echo up || echo down`.
   On macOS, Docker Desktop is `/Applications/Docker.app`, and its socket is
   `~/.docker/run/docker.sock`. `swebench_score.py` sets `DOCKER_HOST` to that
   socket itself. If docker is down, start it, and wait up to 4 minutes:

   ```bash
   open -a Docker
   for i in $(seq 1 48); do docker info >/dev/null 2>&1 && break; sleep 5; done
   docker info >/dev/null 2>&1 && echo up || echo "still down after 4 min"
   ```

   Run the wait loop in a Monitor (timeout 300000 ms), because it is longer
   than a usual tool call. If docker is still down, stop and tell the user.
   Give docker 16 GB of memory or more on Apple Silicon (Docker Desktop >
   Settings > Resources); `docker info --format '{{.MemTotal}}'` shows it.
2. **Disk.** `df -h .` and `docker system df`. The harness pulls the
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

Start the score run so that it survives a tool timeout:

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

Arm a Monitor (30 minutes, the maximum). Re-arm it each time it expires, until
the log has `score complete`, `no instance was evaluated`, or a line that
tells the cause of a stop. Put the run id of step 2 in `RUN`:

```bash
RUN=score_YYYYMMDD_HHMMSS; LOG=bench/score.NAME.log
( seen=""; while true; do
    for f in logs/run_evaluation/$RUN/*/*/report.json; do
      [ -e "$f" ] || continue
      case "$seen" in *"$f"*) continue;; esac
      seen="$seen $f"
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); k=next(iter(d)); print("instance", k, "RESOLVED" if d[k].get("resolved") else "unresolved", flush=True)' "$f"
    done; sleep 30
  done ) &
tail -n 0 -F "$LOG" | tr '\r' '\n' | grep --line-buffered -E \
  'did not run|did NOT run|harness call failed|docker failed|Error|error building|Traceback|Killed|137|docker does not answer|no instance was evaluated|nothing to score|the score:|score complete|the report of this score run'
```

The harness writes no line for a resolved instance, so the loop reads each
new `report.json`. An instance with no `report.json` did not run its tests.
When the run ends, check that no `swebench_score.py` process is left, and
read the exit messages at the end of the log.

## 4. Report

```bash
python3 .claude/skills/swebench-score/scripts/report.py NAME
```

Other forms: `--score FILE.json` (a report that is not the newest),
`--scan FILE` (a saved output of `scan.py` of the swebench skill; its
upstream-fix items are added), `--compare NAME|FILE`, `--no-compare`,
`--root DIR` (the dir where the harness wrote `logs/`). With no argument, the
script uses the newest predictions file that has a score report.

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
- **WEB**: the web state of the config, and a warning when web was on. A web
  search can find the upstream fix of the issue. The script finds it with the
  same pattern and the same transcript pairing as `scan.py` of the swebench
  skill (it loads that script as a module). For a full check, also run
  `python3 .claude/skills/swebench/scripts/scan.py --name NAME`.

Give the user the SCORE lines, the table, the harness errors, and the web
warning. Do not compare a run with web on to a run with web off as if they
measure the same thing.

## 5. Compare

When a score report of an other NAME exists, the script compares with the
newest one that is older than this score. `--compare NAME` (or a score json,
which can also be an other run id of the same predictions) picks one. For each
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
