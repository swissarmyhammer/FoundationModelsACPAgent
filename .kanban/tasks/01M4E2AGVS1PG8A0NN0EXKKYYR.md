---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4e2bqe6cawjygg8njfrj7cb
  text: 'Scope addition (user, 2026-10-08): the run config `bench/code-context.config.yaml` must name each tool group under `tools:` with its state. Use the builtin file of ^shk85xg9dge8cc as the model. Then a run states the full tool set, and not only the groups that differ from the default.'
  timestamp: 2026-10-08T15:33:26.086544+00:00
- actor: claude-code
  id: 01m4e2bvsjtmw4caadk8vgy34a
  text: 'Correction to the comment above: the builtin-file task is ^9dge8cc (01M4E2BEVVM2SHK85XG9DGE8CC).'
  timestamp: 2026-10-08T15:33:30.546583+00:00
depends_on:
- 01M4E2A5G4FC38X7WG4P28XJZ6
- 01M4E2BEVVM2SHK85XG9DGE8CC
position_column: todo
position_ordinal: '8280'
title: 'bench: turn the git tools on in the SWE-bench config, and count them in the scan and the score'
---
## Goal

The SWE-bench runs use the git tools of Multitool, and the run state shows this. The agent task ^p28xjz6 adds `tools.git` with the default `true`.

## Change

1. **Run config.** In `bench/code-context.config.yaml`, add `git: { enabled: true }` under `tools`, with a comment in the style of the `codeContext` and `web` entries. The default is on; the entry is there so that the run states it.
2. **Clone state.** `bench/swebench_run.py` (around line 629) makes a full `git clone`, then `checkout --force <base_commit>` and `clean -fdx`. Thus, the HEAD is detached at the base commit. Check that each git verb gives a correct result on this clone:
   - `tools.git.status` with a detached HEAD.
   - `tools.git.changes` and `tools.git.diff` show the change of the agent against the base commit. This is the same change as the patch that `git diff <base_commit>` makes (`swebench_run.py:452`).
   - If a verb fails, record the defect on the Multitool board. Do not change Multitool from this repo.
3. **Upstream history.** A full clone holds the refs after the base commit (for example `origin/main`). Thus, `tools.git.log`, `show`, `blame` or `commit` with a `rev` argument can read the upstream fix. The user decided that an upstream fix that the agent finds is a valid result, as for the web tool. Do not block it. Make the upstream-fix flag of the swebench-score report also mark a git read of a rev that is not an ancestor of the base commit.
4. **Scan.** `.claude/skills/swebench/scripts/scan.py` counts calls by `tools.<group>.<verb>` (`VERB_RE`, line 50), so the git verbs are counted. Its config reader (line 167) reads only `tools.web.enabled` by name. Make the report also state `tools.git.enabled`. Add a test in `test_scan.py`.
5. **Score report.** The swebench-score report states whether web was on. Make it also state git. Add a test in `test_report.py`.

## Tests

- `python3 -m unittest discover` for `bench/`, `.claude/skills/swebench/scripts` and `.claude/skills/swebench-score/scripts`: all pass.
- One real run of one instance with the new config: the transcript shows at least one `tools.git.*` call, and the scan counts it.

#bench #tools