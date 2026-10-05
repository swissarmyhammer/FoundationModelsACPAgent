---
name: swebench
description: Run a SWE-bench benchmark of this ACP agent, and evaluate it while it runs and after it ends. Takes one argument - a SWE-bench instance id (for example django__django-13447), a number N (run N instances), or nothing (evaluate the run that is in progress now). Use when the user says "swebench", "swe-bench", "run the bench", "bench run", "check the bench run", "watch the bench", "evaluate the bench", or "is the bench healthy". Starts a detached run, finds a live run, watches its log, does a deep scan every 10 minutes, and gives a ranked list of problems with evidence.
license: MIT OR Apache-2.0
compatibility: macOS. Needs swift, uv, git and python3; scoring needs docker. Reads bench/ of this package and the temporary clone of the agent.
metadata:
  author: swissarmyhammer
  version: 0.1.0
---

# swebench

Run SWE-bench Lite against `acp-agent`, and find the real problems in the run.

For the basics of the harness (the steps, the flags, the output files, the
score), read `bench/README.md`. This skill does not repeat them. It adds the
launch checks, the watch, and the evaluation.

**Rules**

- Do not stop, start or change a run that you did not start in this session.
- Do not edit the harness (`bench/*.py`) to do this work.
- Run each shell command so that it exits quickly. For a long job, use a
  detached launch (step A) and a Monitor (step C).
- Write all notes and reports in ASD-STE100 Simplified Technical English.

## The argument

| Argument | What to do |
|---|---|
| an instance id, for example `django__django-13447` | Steps A, B, C, D, E with `-i <id>` |
| a number N | Steps A, B, C, D, E with `--limit N` (or `--sample N` for a sample in the ratio of the split) |
| nothing | Steps B, C, D, E on the run that is in progress now |

More than one id is also possible: `-i id1 id2 ...`. `-i` replaces `--limit`.
For many ids, put them in a file and use `-i $(cat ids.txt)`.

## The names of the outputs

Pick one NAME for each run, for example `code-context` or `django-13447`.
The output paths follow from NAME; `bench/README.md` ("Outputs") lists them.
The run log is `bench/run.NAME.log`, and an agent config is
`bench/NAME.config.yaml`. `scan.py --name NAME` finds all of them. The harness
appends to the predictions file, so use a new NAME for a new run, or `--force`.

## A. Launch

Do these checks first. Stop and tell the user if one fails.

1. **Build.** `swift build -c release`. The harness uses the release build
   first. After a new commit of a sibling package, `swift package update` first.
2. **Config.** If the run uses `--agent-config FILE`, read FILE:
   - Each group in `tools:` must have the state that the user wants. A
     group is on by default; `enabled: false` turns it off. A past run had
     `web: enabled: false` by mistake. Report each group that is off.
   - Report `tools.codeContext.semanticSearch` (false: no embedding pass,
     and `searchCode` answers with an error).
   - **Web needs no key.** With no key, the search uses the free public pages
     of Brave and DuckDuckGo. Do not require a key. If one of these variables
     is set, say its NAME only (never the value): `BRAVE_SEARCH_API_KEY`,
     `TAVILY_API_KEY`, `EXA_API_KEY`, `SERPER_API_KEY`, `KAGI_API_KEY`,
     `SEARXNG_URL`. The harness gives the agent a clean environment
     (`bench/swebench_env.py`), so check that it keeps the variable.
   - With web on, the agent can find the upstream fix. Tell the user that the
     score then does not measure the agent alone.
3. **No collision.** No other run must write the same files:

   ```bash
   ps -axo pid,etime,command | grep -E 'swebench_run.py|acp-agent acp' | grep -v grep
   ls -la bench/preds.NAME.jsonl bench/run.NAME.log 2>/dev/null
   ```

   If a live run uses the same predictions path, do not start. If an old log
   with the same name exists, move it: `mv bench/run.NAME.log bench/run.NAME.log.old-$(date +%H%M)`.
   One agent process uses the GPU; two runs at the same time make both slow.
4. **Launch detached**, so that the run survives a tool timeout:

   ```bash
   nohup sh -c 'uv run bench/swebench_run.py bench/preds.NAME.jsonl --limit N \
     --timeout 5400 --agent-config bench/NAME.config.yaml \
     2>&1 | tee bench/run.NAME.log' > /dev/null 2>&1 &
   ```

   For one instance use `-i <instance_id>` in place of `--limit N`. Add
   `--verbose` for one line for each session event (a large log). The default
   `--timeout` is 3000 s.
5. Wait about 1 minute, then check that the log has `agent binary` and
   `the instances of this run`.

## B. Find a live run

```bash
ps -axo pid,etime,command | grep -E 'swebench_run.py|acp-agent acp' | grep -v grep
P=$(pgrep -f 'acp-agent acp' | head -1)
lsof -a -p $P -d cwd -Fn | sed -n 's/^n//p'          # the temporary clone dir
```

- The harness command line gives the predictions path, so it gives NAME.
  The `tee` target is the run log.
- The agent cwd is a temporary dir. The clone is `<cwd>/repo`.
- The live transcript: `<cwd>/repo/.acp-agent/transcripts/<session>/transcript.jsonl`.
  The harness copies it to `bench/preds.NAME.transcripts/<id>/` only when the
  instance ends.
- The recordings of the tool-selection model: `$TMPDIR/acp-agent-recordings-*/`.
  Many old dirs are there; the scan takes the ones that changed after the run
  started.
- The code context index (read only): `sqlite3 "file:<cwd>/repo/.code-context/kit.db?mode=ro" "select count(*),sum(ts_indexed),sum(lsp_indexed),sum(embedded) from indexed_files;"`

## C. Watch

Arm a Monitor on the run log (30 minutes, the maximum). Re-arm it each time
it expires, until the log has `complete`:

```bash
tail -n 0 -F bench/run.NAME.log | grep --line-buffered -v 'could not mark a changed file dirty' \
  | grep --line-buffered -E 'running the agent|done|EMPTY patch|TOO SLOW|ERROR|NO ENVIRONMENT|not supported|transcripts not kept|complete|Traceback|error|Killed|protocol'
```

The watcher warning `could not mark a changed file dirty` comes in bursts of
thousands. Do not stream it. Count it in the deep scan.

Do a deep scan (step D) about every 10 minutes while the run continues, and
one time after it ends. Use a self-paced loop (ScheduleWakeup or `/loop 10m`).

## D. Evaluate (the deep scan)

```bash
python3 .claude/skills/swebench/scripts/scan.py --name NAME --live --timeout 5400
```

Other forms: `--log`, `--preds`, `--runs`, `--config`, `--transcripts DIR ...`,
`--recordings DIR ...`, `--gap SECONDS` (default 60). A missing file gives a
note, not a failure. The scan works on a live run.

The scan reports these items:

| Area | What it checks |
|---|---|
| Config | groups that are off, `web` state, `semanticSearch`, web key names that are set, the `--agent-config` of the live harness, and a warning when the file changed after the run started |
| Progress | done / total, the time of each instance, a running instance near its limit (more than 80 %) |
| Stalls | gaps of 60 s or more between transcript lines, with the output tokens of the next generation; each stall one time |
| Transcript | missing seq numbers (the router's selection sessions share the seq counter, so a gap is not always a lost line) |
| Tools | calls / errors for each tool and each `tools.<group>.<verb>`; `execute` nonzero exits apart from tool failures |
| Made-up verbs | each `is not a function` error (for example `tools.shell.run`; the correct verb is `tools.shell.execute`), the hint, if the model recovered, and that error as the evidence |
| Web | `web.search` and `web.fetch` calls and errors; zero web calls when web is on; web not offered to the tool-selection model; results that look like the upstream fix |
| Skills / code context | `skills` tool results (`use skill`), `code_context.*` results, `"kind": "instructions"` lines |
| Self-matches | `files.grep` results that contain `.acp-agent/transcripts` lines. `.acp-agent` has no ignore rule in the clone, so grep finds the agent's own transcript |
| Watcher | count, unique files, rate per minute, peak per second, error types, and patched files that also got the warning |
| Log | other warnings and errors by kind, with counts and rate per hour |
| ACP | `acp.protocol_version.requested` / `answered` notices, version fallback, JSON-RPC error lines |
| Output | empty patches, instances that hit the timeout, recovery stop reasons (`_truncated`, `_repeated`, ...) |
| Score | the newest `preds.NAME.jsonl.score.*.json` |

**Limits of the data.** Know these before you trust a number:

- The transcript keeps the code of each `runCode` call. A `"kind":
  "toolCalls"` line has `entry.toolCalls[]`, each with `id` (`call_...`),
  `toolName` and `argumentsJSON`. For `runCode`, `argumentsJSON` is a JSON
  string with a `code` field. The result that the model got is a
  `"kind": "toolOutput"` line with `entry.entryId` equal to the call id. The
  scan pairs the two by that id, and gets the verbs from
  `tools\.([a-z_]+)\.([A-Za-z_]+)` in the code. A snippet with no
  `tools.*` verb counts as `runCode(no tools verb)`.
- An error counts for the verb that it names (`... is not a function`, or
  `Tool "edit" argument ...` for `files.edit`). Else it counts for each verb
  of the snippet.
- The other `toolOutput` lines are operation events:
  `[tool] name (ULID) running|completed|failed: ...`. Each `runCode` and
  `execute` gives a `running ... End your answer now` notice. The scan does
  not count those notices. It counts the `runCode` result of the model
  only, so it does not count one call two times. It counts the final
  `execute` event of each shell command. Read the status from the prefix
  only; a grep result can quote other results that contain `running:`.
- A `runCode` result is an error only when it starts with
  `The snippet failed:`, has `... is not a function`, has a tool argument
  error, or has a JSON key that tells of a failure (`error`, `isError`,
  `status`/`statusCode` of 400 or more or `failed`, or a web `correction`
  with no `results`). The words TypeError, Error or failed in a file or in
  grep output are not errors.
- An `execute` result with a nonzero `exitCode` is normal work (a test that
  fails, a script that stops). The scan shows it apart as "nonzero exit" and
  does not count it as a tool failure. A tool failure is a timeout, a
  command that could not start, or an error key.
- The scan reads the config file as it is now. When the file changed after
  the first line of the run log, the scan gives a warning, shows the config
  in git at the last commit before the run start, and marks each config
  problem "not sure: config changed after the run started". The run log does
  not record the config path; the scan shows the `--agent-config` of a live
  harness process.
- The recordings dir has only the tool-selection model sessions (kinds
  `session`, `instructions`, `prompt`, `response`, `generationCall`). It has
  no ACP traffic. Its `Choose only from these ids:` list shows which verbs the
  agent offered (for example `web.search`), and its `response` rows show which
  verbs the router chose.
- ACP: the harness sends `protocolVersion: 2` (`bench/swebench_acp.py`,
  `PROTOCOL_VERSION`). The agent serves only v2
  (`Sources/FoundationModelsACPAgent/Agent/Initialization.swift`,
  `latestProtocolVersion`). On a mismatch the agent logs a notice with
  `acp.protocol_version.requested` and `acp.protocol_version.answered`, and
  answers v2. A JSON-RPC error makes the harness log `ERROR` for the instance.
  So check the run log; there is no other ACP record.
- The watcher warning keeps only the error type
  (`FoundationModelsCodeContext.CodeContextError`); the SQLite cause is lost.
  The burst comes also for files that nothing changed. If the agent edits a
  file that got the warning, `code_context` can give stale results for it.

**After the run ends** (`complete` in the log, no `swebench_run.py` process):
to score the run, use the swebench-score skill
([`.claude/skills/swebench-score/SKILL.md`](../swebench-score/SKILL.md)). It
checks docker, starts the score run detached, watches it, and gives the
report for each instance. Then do the last deep scan:

```bash
python3 .claude/skills/swebench/scripts/scan.py --name NAME --timeout 5400
```

## E. Report

Give the report in this order. Keep it short.

1. **Problems**, ranked, most harmful first. Only real problems. Each one has
   its evidence: a file and seq number, a log line, or a count. Use the
   `PROBLEMS` part of the scan as the start, and check each item by hand
   before you report it.
2. **Progress**: done / total, the instance that runs now and its time, empty
   patches, timeouts, and the score when there is one.
3. **Tool stats**: calls / errors for each tool and verb, web calls, skills,
   code context, made-up verbs, self-matches, the watcher count.

Do not compare a run with web on to a run with web off as if they measure the
same thing.
