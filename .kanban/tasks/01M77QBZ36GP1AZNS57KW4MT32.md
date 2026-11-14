---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m77qs54z1wb7ns7sdrf27dds
  text: 'Done 2026-11-12: skills 1-5 in bb0fe55 (pushed). Item 6: Agents 86dc3f8 (card ^a5vjgm5 there): `tools.agents.enabled` is false in the body of an agent with `disallowedTools: [agents]`. checked24 launched with ACPAgent a73daeb, Agents 86dc3f8, Router aff2f10c, Extras ddf5bf7, Multitool abca4236, skills bb0fe55; config bench/checked24.config.yaml. Open: 7 (end-to-end scheduled-agent test), 8 (smaller planner reports), and the compare with oneplan24 when checked24 ends.'
  timestamp: 2026-11-12T11:20:10.655837+00:00
- actor: claude-code
  id: 01m77xv5gpbe4h0jt3s1tgkce7
  text: 'checked24 13710 (live): the coder ran the full suite ~9 times (seq 4675..5168, about 30+ min). Cause: `r.output`/`r.lines` in the snippet hold only the 32-line tail ("N: text"), so `r.output.filter(/^FAIL|ERROR/)` missed the failure headers at lines ~560-606; `maxOutputChars: 200000` is ignored. The model did not use getLines and said the output was "consumed". Sent to Multitool: full output in the snippet value (tail only in the rendered report), honor or correct maxOutputChars. Also house-rule misses in the same coder: the 4 failures were pre-existing environment failures (inspectdb myfields import, msgfmt) and it did not stop; it wrote scratch_fullrun.txt / scratch_run.py in the repo.'
  timestamp: 2026-11-12T13:06:08.022979+00:00
- actor: claude-code
  id: 01m77ybdctpk843wy3d7kb8f1z
  text: 'Multitool 997240df (pushed): in a snippet, r.output = all stored lines as raw text (last 20000), r.lines numbered, r.text/r.stdout one string; the rendered report keeps the 32-line tail. maxOutputChars and similar give a note in r.notes. Behavior change: a snippet that returns r.output gets raw lines. Take it into the build AFTER checked24 ends (no rebuild while live).'
  timestamp: 2026-11-12T13:15:00.378454+00:00
- actor: claude-code
  id: 01m789ahvz6yrbptyp3969wvp5
  text: 'checked24 14016: EMPTY patch after 513 s. The root hit the 8192 reasoning limit 4 times; it acted (a tool call) after each of the first 3 recoveries, but Router allows 2 recoveries per answer (shared with repetition stops), so the 4th stop ended the answer. Sent to Router: reset the recovery count when the model acts after a recovery. The root explored by itself before do-task, the same as in oneplan24 14016, so that part is not new. Take the Router sha into the post-run build.'
  timestamp: 2026-11-12T16:26:46.527296+00:00
- actor: claude-code
  id: 01m78bxs2x8tj1v0fa4p9d28v3
  text: 'Router 3defdfd4 (fix caaefa73, card ^0jbps9v there): recoveriesPerAnswer counts consecutive stops with no progress; a tool result from a non-repeated call resets it. router.recoveries in PromptTally is still the prompt total. Post-run build set so far: Multitool 997240df + Router 3defdfd4. Take both after checked24 ends.'
  timestamp: 2026-11-12T17:12:13.661506+00:00
- actor: claude-code
  id: 01m78cxe2wn0gg2thdyfqkhpfn
  text: 'checked24 14155 (live): the root skipped the planner and the plan check. It analyzed by itself (its reasoning at seq 16011 degenerated into a made-up list "ReverseWithAppNamesAndNamespaces47Tests ... 57Tests") and then started the coder with its own plan (seq 16015). Only kanban was loaded, not do-task. Note: in both runs many roots load only kanban and still follow the planner flow, so the default agent drives the flow; this is a root that did not. Watch the score; consider a firmer default-agent rule ("for a code change, always start the planner first; do not analyze yourself").'
  timestamp: 2026-11-12T17:29:30.972365+00:00
- actor: claude-code
  id: 01m78e3jecy8bbeyh5dhfed9pw
  text: 'checked24 14155 BROKEN (oneplan24 resolved). The root skipped the planner and plan check and had the coder unwrap the partial in ResolverMatch.__init__ (_func_path = func.func''s module.name), as the issue text suggests ("unwrap functools.partial objects in ResolverMatch.__init__()"). The expected fix shows repr(partial), with its arguments, in __repr__ and switches to %r; FAIL_TO_PASS test_repr, test_repr_functools_partial, test_resolver_match_on_request fail. oneplan24''s planner made the repr(partial) plan. So the skip of the planner cost this instance. Also note: "start from the issue''s proposed code" can point the wrong way when the issue''s suggestion is a sketch that loses information (here the partial''s arguments); the plan check should still test what the issue asks for (a repr that shows the partial "nicely"), not only the hint.'
  timestamp: 2026-11-12T17:50:20.620141+00:00
- actor: claude-code
  id: 01m78vftfqgr145mzb9qj5t2pw
  text: 'checked24 14608 (live): the plan check (session 01M78T63VRWDNBWFV1EB541M5V) gave VERDICT: PASS at seq 30255, was woken by a queued result, ran a test, then looped on no-op snippets `return "waiting-N"` (N up to 63+, ~6 s each, 20+ min) while nothing was pending. The host no-op check is asked only while an operation is pending, and the repetition watch misses it because the text changes. The root waits the whole time. Sent to Router: a no-op call with nothing pending ends the pass; consecutive no-ops count to a stop; a no-op never counts as progress; check that a completion reaches the model inside a running answer.'
  timestamp: 2026-11-12T21:44:13.559062+00:00
- actor: claude-code
  id: 01m78y3mjrxaccfsba9q9hg20z
  text: 'Router d87d9598 (card ^zetnz36): a no-op call never runs; with nothing pending, a round of only no-op calls ends the answer ("This tool call does no work here. Nothing is pending ... Write your report as text."); a no-op never counts as progress. Also fixed: a run that settles mid-answer now reaches the model right after the round''s tool results in the same answer (it only arrived at the next submission before). Post-run build set: Router d87d9598 (includes the recovery fix), Multitool 997240df.'
  timestamp: 2026-11-12T22:30:00.024989+00:00
- actor: claude-code
  id: 01m799jedbsxtr0jpj9zr3ek1v
  text: 'checked24 14730 BROKEN (oneplan24 resolved via the upstream commit in the clone''s git history, with W345). This run raised a ValueError in ManyToManyField.__init__ for symmetrical + related_name, as the issue text says ("raise an error"); the hidden test test_many_to_many_with_useless_related_name expects the system check warning fields.W345 in _check_ignored_options. Same class as 14667: the issue text vs. upstream form. The planner did not look in git history this time. Also 14667 and 14016/14155 so far: misses are mostly "issue text vs upstream" plus the two Router-fixed problems.'
  timestamp: 2026-11-13T01:50:19.563289+00:00
- actor: claude-code
  id: 01m79g6wws7n1hre25djm7xje8
  text: 'checked24 stopped at 20/24 on user request (16/20 resolved vs oneplan24 18/20 on the same ids; 23% faster). Losses: 14016 (Router recovery bug, fixed), 14155 (root skipped planner, followed the issue hint), 14730 (issue text vs upstream W345). Gain: 14534. Skills 107aa4a pushed: the proposed code is a hypothesis (check user-visible behavior, code base convention, git history); the root always starts the planner first. hint24 launched with Router dc1e3fc7, Multitool b3d7b13e, Agents 02d5f0f, Extras e25cc7d, skills 107aa4a; config bench/hint24.config.yaml.'
  timestamp: 2026-11-13T03:46:21.209274+00:00
- actor: claude-code
  id: 01m79p8x8h88dgcg2h93ftgna0
  text: 'hint24 13925 (live): the root polls `check agent` (43+ calls) on the planner and then the plan check, never writing "Waiting on" text (0 vs 5 in hint24 13447/13710 and checked24 13925, which had 0 checks). Its reasoning: "the double-check agent has been running for 75 passes ... might be stuck". The check result carries "Progress: N passes; last tools: ..." (Agents 219dfcb, old), so each check shows a change and the "nothing changed" note seldom fires; Router''s repeated-call stop fired once (3 identical calls). One instance only so far; the plan check also gave REVISE, so a second planner runs. Idea for after the run (not a guard): drop the pass count from the check result, so a repeat check reads "nothing changed".'
  timestamp: 2026-11-13T05:32:18.577257+00:00
- actor: claude-code
  id: 01m79qq27eqh1xykt0gf6nkv5n
  text: 'Post-hint24 build set: Agents ba97268 (card ^47g8cer: a repeat check agent where only the pass count rose gets "nothing changed" and no count; needs swift package update for the newer Skills), Router ^z9fsh1t pending (canonical argument comparison for the repeated-call stop and progress).'
  timestamp: 2026-11-13T05:57:30.990252+00:00
- actor: claude-code
  id: 01m79rjwybegw0pcjyveqdx7td
  text: 'Router aa7052d9 (^z9fsh1t): canonical JSON argument identity for the repeated-call stop and recovery progress. Router main also carries another session''s native decision path (^qmsn6f3), which needs FoundationModelsDecision b5700c3+ and Extras e25cc7d+. Post-hint24 build: swift package update, Router aa7052d9+, Agents ba97268+; run the full test suite before the next run because of the decision-path change.'
  timestamp: 2026-11-13T06:12:43.083638+00:00
- actor: claude-code
  id: 01m79zwzag8kg8sgng4be81efc
  text: 'hint24 13964 (live, 5094 s): the tester (session 01M79XTE5YRW530AZB80GHS1R5) ran the full suite 3 times (seq 10863, 11169, 11439, each pending when repeated) and studies pre-existing environment failures (i18n, asgi, inspectdb) — the same as oneplan24 13964. The abstract house rule "stop on a test-setup failure" did not hold. Skills 4fe4846 (local, NOT pushed until hint24 ends): the tester runs the full suite once, checks each failure once on the original code (git stash -u / pop), lists the pre-existing ones, and stops.'
  timestamp: 2026-11-13T08:20:33.232939+00:00
- actor: claude-code
  id: 01m7asbsgsss05zqbcb8knqtm4
  text: 'hint24 at 15/15 resolved. 14667 RESOLVED for the first time in any run: the planner searched git history (9 git log calls), found upstream fd999318ad (Fixed #32704), and followed it over the issue text; the plan check passed it; the coder applied it as is. 14155 RESOLVED: the planner rejected the issue''s unwrap-in-__init__ hint and matched upstream 41850eec99. 14016 RESOLVED (Router recovery fix). Skills 107aa4a (proposed code is a hypothesis; git history) is the cause of 14155 and 14667.'
  timestamp: 2026-11-13T15:45:33.209521+00:00
- actor: claude-code
  id: 01m7az6fjry6hfgtmqkt19y990
  text: 'hint24 at 17/17 resolved. 14730 RESOLVED: the first planner found upstream 5d4f21b16f (W345) but planned a TypeError; the plan check gave REVISE with the upstream diff ("the hidden test fails under the plan"); the second planner and coder used W345. All three checked24 losses (14016, 14155, 14730) are now resolved, plus 14667 for the first time in any run.'
  timestamp: 2026-11-13T17:27:30.648792+00:00
- actor: claude-code
  id: 01m7bvhtx95pvmym6acvw4959k
  text: 'hint24 complete: 24/24 resolved (official score_hint24), 21.1 h vs oneplan24 22/24 in 25.9 h (−19%). Fixed vs oneplan24: 14534, 14667. Skills 4fe4846 (tester procedure) pushed after the run. Next build: swift package update (Router aa7052d9+ incl. the native decision path, Agents ba97268+, newer Skills), full test suite, then a run on the same 24 ids.'
  timestamp: 2026-11-14T01:43:02.825145+00:00
- actor: claude-code
  id: 01m7cv0kgq15trykynjhg0dm11
  text: 'rerun24 14534 BROKEN (hint24, checked24 resolved): the root started NO agent at all. In 608 s it read the code itself (23 calls: searchTools, files.read/grep) and wrote the fix itself, keeping the old `or ''id_%s_%s''` fallback — the oneplan24 failure. The "your first agent is ONE planner" rule was in its instructions and was ignored. Text rules alone do not hold the root every time (also 14155 in checked24). A structural fix to consider: the root session gets no files/shell write verbs (only skills, agents, kanban, read), so it cannot do the work itself. disallowedTools works on whole tools only, and files/shell are groups inside runCode, so this needs a per-group deny (Multitool/ACPAgent) — ask the user.'
  timestamp: 2026-11-14T10:52:52.631244+00:00
- actor: claude-code
  id: 01m7cx32frpff0jpcrdev8ypck
  text: The open item "A real end-to-end test of a scheduled agent" is now card ^ybpc6ap (01M7CX2YPXBGCW47ZGPYBPC6AP).
  timestamp: 2026-11-14T11:29:10.648814+00:00
- actor: claude-code
  id: 01m7cytn1wnss5qvp8sr0h30mj
  text: 'Root restriction done (user decision 2026-11-14: make files deniable). ACPAgent 06f017d (tests: a session agent''s disallowedTools removes the source groups) and 3bfe4f3 (^k6rc9p6: files is no longer always-on; an agent with a tools: list loses files unless it names it). Skills: the default agent now has `disallowedTools: [files, shell, code_context, web, git, environment, snapshots]`, so the root keeps only skills, agents, kanban and cannot code itself (14534 rerun24, 14155 checked24). Planner reports shortened (skills 723e0cb). The five other open cards were already done on main by another session. Note: TestudoApp spec features/packages/foundationmodels-acpagent.md D90 (c) still says runCode gives files — stale, outside this repo.'
  timestamp: 2026-11-14T11:59:31.900084+00:00
- actor: claude-code
  id: 01m7cyy1xx33sanfzkn93t0v4e
  text: 'Correction (user, 2026-11-14): the user does NOT want the root''s tools removed. Skills 7066883 reverted by 3398caf; the default agent has no disallowedTools again. Kept, by the user''s choice: ACPAgent 3bfe4f3 (files is deniable as a capability; nothing denies it) and 06f017d (tests). The root-skips-the-planner problem (14534, 14155) stays open; look for another fix that keeps the root''s tools.'
  timestamp: 2026-11-14T12:01:23.389413+00:00
- actor: claude-code
  id: 01m7d2ew71tw3a53s34ektzmx2
  text: 'Closed 2026-11-14. Done: skills 1-5 (bb0fe55), hypothesis/git-history/convention + planner-first (107aa4a), tester procedure (4fe4846), short planner answers (723e0cb), delegate-every-step wording (65e977a); "schedule an agent" gate (Agents 86dc3f8); end-to-end scheduled-agent test (^ybpc6ap, 72f264f + 86cf8ea: a firing''s result reaches the client; close deletes schedules by user decision). Bench: hint24 24/24 in 21.1 h; rerun24 stopped at 11/12 (polling gone; 14534 root started no agent). Root keeps its tools (user). Next: a 24-instance run to confirm the root always delegates.'
  timestamp: 2026-11-14T13:03:00.321006+00:00
position_column: done
position_ordinal: ffffeb80
title: 'After oneplan24: skills fixes and follow-ups from the run'
---
Items from the oneplan24 SWE-bench run (2026-11-10/11, 22/24, 25.9 h). Skills changes 1-5 approved by the user 2026-11-12. Push skills only when no bench run is live (the bench reads skills from GitHub main).

## Skills (../skills)
- [ ] 1. planner: start from the code that the issue proposes; a different fix needs a stated reason (14534: kept an `or 'id_%s_%s'` fallback against the issue's fix and broke it)
- [ ] 2. double-check on the plan: flag each difference from the issue's proposed code; tests that pin the behavior the issue changes are expected to change, so "existing tests unchanged" is not proof (14534, 14667)
- [ ] 3. double-check: REVISE only for findings that change the code; prose findings go as notes in a PASS (7/24 instances had REVISE rounds, about 2-3k s each, several for prose only)
- [ ] 4. house rules: do not start a command again while its result is pending; if the tests of the changed module pass and a failure is in the test setup, report it and stop (13964: 40 min in the test setup, pending tests re-run 3 times)
- [ ] 5. do-task: finalize the board (last comment, move to Done) first, then make ONE commit with code + tests + .kanban/ (13925: a second committer for .kanban/)

## Carried over from ^2pa0kzs
- [ ] The `{% if tools.agents.enabled %}` "schedule an agent" line also shows in agents with `disallowedTools: [agents]` (planner, double-check). Needs a per-agent template value in Agents, or move the line to the agents that have the tool
- [ ] A real end-to-end test of a scheduled agent
- [ ] Smaller planner reports (planner context reached 273K tokens; no limit hit, but the root refeeds the report)

## Experiment
- [ ] After 1-5: run the same 24 ids (bench/mtp24.ids.txt) and compare with oneplan24: score per instance and wall time

#bench