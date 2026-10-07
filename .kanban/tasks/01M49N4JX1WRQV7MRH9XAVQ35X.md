---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4b5q5zfww72tznhraxbqehp
  text: |-
    Research (implement):
    - No file on disk records the agent config of a run. `bench/preds.NAME.runs.jsonl` has no config field, `bench/run.NAME.log` has no `--agent-config` text, and the transcripts (session.json) do not hold the tools config. The shell log cuts the command line. Thus the card source "read the config path from the record" does not exist yet.
    - Decision: `bench/swebench_record.py` gets a 17th field `agent_config` (the `--agent-config` path, or null). `bench/swebench_run.py` gives it, and writes a log line `the agent config agent_config=PATH`. `report.py` reads the record first, then the log (`--agent-config PATH` or `agent_config=PATH`), then `bench/NAME.config.yaml`.
    - The old runs `final-pass-check` and `recovery-check` have no such data. Their local record files (gitignored) get `agent_config: bench/code-context.config.yaml`, from the statement of the user. recovery-check transcripts show web.* calls, which agrees.
    - The resumed score of `code-context-1006` holds 15 ids (django__django-13925 has an empty patch and is not in the resumed score), but its predictions hold the same 16 ids as `code-context`. Thus the instance ids of a run come from the predictions file, with the score ids as the fallback.
    - `--compare NAME` exists already in report.py.
  timestamp: 2026-10-07T12:34:23.855512+00:00
- actor: claude-code
  id: 01m4b6063n8msxw7vhpx6syz7z
  text: |-
    Implementation landed (not committed):
    - report.py: `run_ids` (the ids of the predictions file; the score ids only when there is no predictions file), `compare_target` gives (score, why) and takes only a run with the same ids, newest first, a score older than this score first. With no such run it compares with nothing and says "name one with --compare NAME". `--compare NAME` is unchanged and takes the named run also with other ids. COMPARE prints "the report took this run because it is ...".
    - report.py: `config_of` = record field `agent_config`, then the head of bench/run.NAME.log (`agent_config=PATH` or `--agent-config PATH`, only the lines before the first "running the agent"), then bench/NAME.config.yaml. A relative path is relative to the parent of the bench dir. The WEB line now prints the state and the path. `main(argv=None)` for the test.
    - bench/swebench_record.py: 17th field `agent_config`. bench/swebench_run.py: gives `args.agent_config` to `run_record`, and logs `the agent config agent_config=PATH` before the first instance.
    - .github/workflows/bench.yml: new step that runs the tests of .claude/skills/swebench-score/scripts (a test target that no CI task runs gives no protection).
    - Docs: SKILL.md of swebench-score (WEB and Compare), bench/README.md (record row).
    - Local data, gitignored: bench/preds.final-pass-check.runs.jsonl and bench/preds.recovery-check.runs.jsonl got `agent_config: bench/code-context.config.yaml`, from the statement of the user. Copies of the old files are in the session scratchpad (runs-backup/).
    Real data: `report.py code-context-1006` compares with `code-context` ("the newest other run with the same 16 instance ids"; fixed 3, broken 1, same 11, only one run 1). `report.py final-pass-check` gives "WEB: config on (bench/code-context.config.yaml)". recovery-check also gives web on.
    Open fact: no file names the config of `code-context-1006` (its record and log have none, and the shell log has no command line), so its WEB line says "config unknown" and the compare gives a warning. If a person confirms that it used bench/code-context.config.yaml, add `agent_config` to its record rows.
  timestamp: 2026-10-07T12:39:18.901886+00:00
- actor: claude-code
  id: 01m4b608v3095padz012sz0e4p
  text: |-
    ### implement — changed
    - evidence: 8 files — .claude/skills/swebench-score/scripts/report.py, .claude/skills/swebench-score/scripts/test_report.py (new), .claude/skills/swebench-score/SKILL.md, bench/swebench_record.py, bench/swebench_run.py, bench/test_swebench_record.py, bench/README.md, .github/workflows/bench.yml. `python3 -m unittest discover --start-directory bench` 224 tests OK (1 earlier skip: swebench not installed); `python3 -m unittest discover --start-directory .claude/skills/swebench-score/scripts` 14 tests OK. TDD: RED seen for both test files before the code.
    - next: /review
  timestamp: 2026-10-07T12:39:21.699837+00:00
- actor: claude-code
  id: 01m4b64b76680q17231946ayy6
  text: |-
    ### test - green
    - bench tests (swebench 5.0.2 installed): 224 run, OK, 0 skipped.
    - skill tests: 14 run, OK. bench.yml step "Test the scripts of the swebench-score skill" runs the same command (python3 -m unittest discover --start-directory .claude/skills/swebench-score/scripts --pattern 'test_*.py').
    - py_compile: 5 changed .py files ok. report.py code-context-1006 exit 0 and compares with code-context (fixed 3, broken 1, same 11). report.py final-pass-check exit 0 and says "web was on".
    - swift test (scratch path rel-build): 744 tests in 83 suites passed, 0 failed. One known issue is a deliberate withKnownIssue in HarnessSmokeTests (orderedSubsequenceAssertionChecksOrderWithGaps), a file this change did not touch. One build warning from the mlx-swift bundle, not from this change.
    - next: review
  timestamp: 2026-10-07T12:41:35.206966+00:00
position_column: doing
position_ordinal: '80'
title: 'report.py: compare with a run that has the same instances, and read the config of the run'
---
`.claude/skills/swebench-score/scripts/report.py` has two bugs.

1. **It compares with the wrong run.** It takes the newest other score json. On 2026-10-06 it compared the 16-instance run `code-context-1006` with the 2-instance check `recovery-check`, not with the 16-instance baseline `code-context`. Fix: take the newest other run whose instance ids are the same. Also add `--compare NAME`, so that a person can name the run.
2. **"web config unknown".** It finds the config file from the run name. For a run named `final-pass-check` or `recovery-check` that used `bench/code-context.config.yaml`, it cannot find the config, so it cannot tell if web was on. Fix: read the config path from the run's record (`bench/preds.NAME.runs.jsonl`) or from the `--agent-config` argument in the run log.

## Acceptance Criteria
- [x] With no `--compare`, the report compares with the newest other run that has the same instance ids, and it says which run it took.
- [x] `--compare NAME` compares with that run.
- [x] The web line of the report gives the real config of the run, for a run whose name is not the config name.

## Tests
- [x] A test with three fake score files (the same instances, other instances, and newer) checks which run the report takes.
- [x] A test with a run named `x-check` that used `bench/code-context.config.yaml` checks that the report finds web on.

#bench