---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4br59pmvw7e8nb1xfp6awre
  text: |-
    Research and implementation notes.
    - No test checked the old text before this work. I added new tests: test_scan.py class AnUpstreamFixFromTheWebIsInformation (3 tests), test_report.py class AnUpstreamFixFromTheWebIsInformation (4 tests). RED was seen for each changed behaviour before the change.
    - scan.py: removed the ranked problem (score 86) for upstream-fix results. The TOOLS line "== results that look like the upstream fix (web): N [...]" stays unchanged. report.py parses that line with SCAN_UPSTREAM, so do not change its text.
    - report.py: removed the WEB WARNING. The line "resolved without an upstream fix seen: X/Y" is now "resolved with an upstream fix seen: X of Y resolved" (information). The COMPARE "WARNING: web is A before and B now; ... do not measure the same thing" is now "web is A before and B now: the two runs use different tools, so this is a comparison of two configurations". Docstring parts 5 and 6 changed to match.
    - Text: bench/code-context.config.yaml comment, bench/README.md, swebench/SKILL.md (launch check, Web row, report part), swebench-score/SKILL.md (WEB item, report sentence, Compare part).
    - Note: rg skips the hidden .claude dir unless --hidden is given. Use --hidden to search the skills.
    - Not changed (true text about other things): "A run with other instances does not measure the same thing" (report.py, swebench-score/SKILL.md), and "measure the agent against the plain task" (bench/swebench_prompt.py, bench/swebench_run.py).
  timestamp: 2026-10-07T17:56:40.788252+00:00
- actor: claude-code
  id: 01m4br5dckkb259rm98yczbegg
  text: |-
    ### implement — changed
    - evidence: 8 files — bench/code-context.config.yaml, bench/README.md, .claude/skills/swebench/SKILL.md, .claude/skills/swebench/scripts/scan.py, .claude/skills/swebench/scripts/test_scan.py, .claude/skills/swebench-score/SKILL.md, .claude/skills/swebench-score/scripts/report.py, .claude/skills/swebench-score/scripts/test_report.py. Tests: swebench/scripts 19 OK, swebench-score/scripts 29 OK, bench (uv run --with swebench==5.0.2) 227 OK. No Swift change.
    - next: /review
  timestamp: 2026-10-07T17:56:44.563594+00:00
- actor: claude-code
  id: 01m4br67j1y9vavssesdwwp7wm
  text: |-
    ### test — green
    - evidence: swebench scripts 19 OK; swebench-score scripts 29 OK; bench (swebench 5.0.2) 227 OK, 0 skipped. No Swift change.
    - next: commit f7601e7, review HEAD~1..HEAD
  timestamp: 2026-10-07T17:57:11.361672+00:00
- actor: claude-code
  id: 01m4brh3zehsedypk47wmm98c0
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (f7601e7): 0 findings, 0 confirmed, 1 refuted, 8 attempted, 0 failed. 4 files had no matching validator (2 SKILL.md, bench/README.md, bench/code-context.config.yaml). 2 .kanban files were excluded by .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-07T18:03:08.142278+00:00
- actor: claude-code
  id: 01m4brhdgtv1nck4mqsfrkptjj
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (config comment, README, 2 SKILL.md, scan.py, report.py, 2 test files)
    - test: green — scan 19, report 29, bench 227
    - commit: f7601e7
    - review: clean — 0 findings
  timestamp: 2026-10-07T18:03:17.914534+00:00
position_column: done
position_ordinal: ffa380
title: 'bench: an upstream fix that the agent finds on the web counts; report it as information, not as an invalid score'
---
## Decision (user, 2026-10-07)

"If you can find the answer and use it, that counts." The web tool is part of the agent. When the agent finds the upstream fix of an issue with `web.search` or `web.fetch` and uses it, the result is a valid result of the agent. Do NOT add a block list for upstream sources. No Multitool change is necessary.

## Why this task changes

Found in the SWE-bench run `bench/preds.code-context.jsonl` of 2026-10-05: in `django__django-13447` the agent used `tools.web.fetch` to get the Django ticket and the upstream commit patch, and the instance was resolved. The bench text now says that such a score "does not measure the agent alone" and that it is not valid. That text is wrong after the decision above.

## What to do

1. Find each text that calls a score with web on not valid, or says that it does not measure the agent alone, and change it. Places to check (find them by text, line numbers can move):
   - `bench/code-context.config.yaml` (the comment above `web:`),
   - `bench/README.md`,
   - `.claude/skills/swebench/SKILL.md` and `.claude/skills/swebench/scripts/scan.py` (the problem "the agent got what looks like the upstream fix from the web"),
   - `.claude/skills/swebench-score/SKILL.md` and `.claude/skills/swebench-score/scripts/report.py` (the WARNING "web was on. A web result can hold the upstream fix, so this score does not measure the agent alone. Do not compare it with a run with web off", and the line "resolved without an upstream fix seen").
2. Keep the detection of an upstream fix in the web results, as information: it shows how the agent solved an instance. Do not rank it as a problem in `scan.py`, and do not mark the score as not valid in `report.py`.
3. Keep one true statement: a run with web on and a run with web off use different tools, so a comparison of the two is a comparison of two configurations.

## Acceptance

- [x] No bench text, skill text or script output says that a score with web on is not valid or does not measure the agent.
- [x] `scan.py` shows web results that look like an upstream fix as information, not in the ranked problems.
- [x] `report.py` shows the upstream-fix column and the web state, and no longer prints the WARNING.
- [x] The tests of the skill scripts and the bench tests pass.

## Tests

- [x] Update the tests of `scan.py` and `report.py` that check the old warning or the old problem.
#bench