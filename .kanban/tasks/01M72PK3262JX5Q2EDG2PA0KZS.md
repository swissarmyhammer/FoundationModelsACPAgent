---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m731a0bc4bx98sbzzkkqtgkd
  text: 'Peers, added 2026-11-10: Agents — the root polled `check agent` 60 times in 14752 (root session ...KRBJHK, 34 calls at 15:17 alone). It writes "I''ll end my turn" and checks again in the same turn. That cost 679 s of model call time (37–42K-token refeed each). Sent to the Agents session with options: a repeat check of a running agent ends the turn, or is refused. Take the sha into the post-run build.'
  timestamp: 2026-11-10T15:30:27.820080+00:00
- actor: claude-code
  id: 01m731hqxhqv26b1trxxpdzeps
  text: 'Agents 643cfdb is pushed (card ^4ys0a29 in Agents): a repeat `check agent` with no change now returns only a short text, "...nothing changed: it is still working. Do not check it again ... If no work is left, post your status as plain text now". It is tracked per run and per caller, so checking two planners in alternation works too. It is text only; if the model still loops, a hard stop must come from the Router. Note: Agents 41baf43 adds the .Cxx interop loop for the new Router, so Agents main now needs Router main too. Take Agents 643cfdb, Router main and Extras d5a812f together in one post-run build, with the .Cxx loop in this repo.'
  timestamp: 2026-11-10T15:34:41.329296+00:00
- actor: claude-code
  id: 01m7386kjbe244fw1x7j1xrfhx
  text: 'Skills: added the general-purpose `double-check` agent (agents/double-check/AGENT.md, adapted from swissarmyhammer builtin). It is committed locally in ../skills as 72024b5, on top of 88d0212, and NOT pushed: the bench reads skills from GitHub main, so push it after planner24 ends. It checks a plan or a change, is read-only by rule (disallowedTools: [agents]), reads the existing tests of the changed functions, gives a VERDICT: PASS/REVISE with Where/Problem/Fix, and posts its report as a kanban comment. Next: have do-task call it, both on the plan before the coder starts and on the change in place of the coder-as-reviewer. Also note: 88d0212 ("ste nudge", default/general-purpose/planner/tester + new ste skill) reached skills main at 15:17 UTC on 2026-11-10, during the run, so instances from about 14787 on may have run with it.'
  timestamp: 2026-11-10T17:30:56.459823+00:00
- actor: claude-code
  id: 01m738e9vhcezjba7f1svqtq8h
  text: 'Skills done locally, NOT pushed (push after planner24 ends): 6e7a184, on top of 72024b5 (double-check agent). do-task now runs: one planner → double-check on the plan (task + existing tests of the changed functions; REVISE → a new planner with the findings) → one coder → test → double-check on the change in place of coder-as-reviewer (REVISE → coder fixes, or back to planning if the plan is wrong). The default agent''s table is updated. The planner drops the "debate / don''t read other comments" text and checks errors before data. This covers the card items: one planner; plan check; root don''t re-check the plan; planner part of r.errors. Still open in skills: no polling / no status mail, tester changed modules only, scratch logs outside the repo, .kanban committed with the work, kanban skill r.errors, shorter root turns.'
  timestamp: 2026-11-10T17:35:08.657882+00:00
- actor: claude-code
  id: 01m738rw19jkjx80mekkdmyh0c
  text: 'Skills, local, NOT pushed: 9ffe535 adds `_partials/house-rules.md`, included at the end of all 7 AGENT.md files. It says: never sleep; never check running work again (agents, getLines, logs); no status mail to the caller; when only waiting, post the status as plain text and stop; to act later, `schedule agent` (shown only when the agents tool is on); scratch files outside the repo. After the build, check that the marketplace render resolves the include for every agent, the default agent included (defaultAgentInstructions has no leftover "{% include"). Multitool was sent two guards: a repeat getLines on a running command gives a short "don''t read again" text, and a wait-sleep (sleep N above a small bound, or a sleep loop) is refused with a "schedule an agent" correction.'
  timestamp: 2026-11-10T17:40:54.953705+00:00
- actor: claude-code
  id: 01m738tknwdjwq8k2v5yf2m3xw
  text: 'Withdrawn: the user does not agree with the Multitool shell guards (repeat-getLines short text, refuse wait-sleeps). The request to Multitool is cancelled. The no-sleep / no-poll rules live only in the skills house-rules partial. The caller-message rule now allows an error, a blocker, or a finding that changes the task (374e7c8, local).'
  timestamp: 2026-11-10T17:41:51.932781+00:00
- actor: claude-code
  id: 01m73907mcvmzd051pksawanxj
  text: 'Decided: no check-agent guard. Agents was asked to revert 643cfdb, and to change the send caller example and the tool description to "only for a critical error you cannot recover from" (each message wakes the caller; the final report comes on its own). Take the Agents sha with the revert into the post-run build.'
  timestamp: 2026-11-10T17:44:56.204762+00:00
- actor: claude-code
  id: 01m73b3kq93bxr5d1x3z6xd0rb
  text: |-
    Post-run build set (pushed by peers 2026-11-10):
    - Agents 7ad4293: reverts the check-agent guard (1e1e8d0), adds the send caller rule; rebased on the add/edit/remove agent work.
    - Extras b4e12ae: did-you-mean for unknown fields/args; includes 1935608 and d5a812f.
    - Multitool 6e648dc2: a failed runCode shows the errors its tool calls returned. BREAKING: it sits on MT-15 (0d1e85f), where MultiTool.Builder has no default mode, so the host must call Builder(mode: .open) or .sandboxed (ToolMode comes from Extras). Multitool fca36a8 also has the .Cxx interop for Router.
    - Router main: GGUF, .Cxx, ModelReferenceFormat, LiveLLMContainer.
    Decided: tester keeps the full suite (item 3, no change). Verb hint: no change (item 8). Skills done locally: 17feae0 (r.errors in kanban; .kanban/ in the same commit, in code-commit) and 85d1dd7 (long bodies in variables as joined lines). Skills now 7 commits ahead of origin, to push after the run.
  timestamp: 2026-11-10T18:21:44.041721+00:00
- actor: claude-code
  id: 01m73c0tqa578pyj6d7ppmaaz4
  text: 'Item 9 (restored scheduled agents get no work lease): the gap is not in Agents; it already takes a workSite. ACPAgent passes nil because the session WorkRegistry is internal to Router (RoutedSessionActor.workRegistry). I asked Router for a public "begin background work on a session" API. Then in this repo: SessionResumeNested.restoreScheduledAgents passes workSite, with a test (a restored firing keeps the session out of no-work until it ends). Item 10 (snapshot race): dropped.'
  timestamp: 2026-11-10T18:37:41.482846+00:00
- actor: claude-code
  id: 01m73f6g643rkdygjc7znv29se
  text: 'Router 864f7290 (feature 2b3d38bd, card ^w4mn68x) adds `nonisolated func beginBackgroundWork(_ kind: WorkKind, id: String) -> BackgroundWork` on RoutedSession. Wire it in SessionResumeNested.restoreScheduledAgents: `workSite: { session.beginBackgroundWork(.childSession, id: $0) }`, and also for schedules made in a live session if they take a work site. BREAKING: the test conformer CloseCountingRoutedSession must implement it. Item 6 (shorter root turns): dropped.'
  timestamp: 2026-11-10T19:33:13.028827+00:00
- actor: claude-code
  id: 01m73vjn3jnrntf2vb6c8mdffy
  text: 'oneplan24 started 2026-11-10 16:47 (config bench/oneplan24.config.yaml, skills 85d1dd7). First scan: the flow is right (planner > double-check/plan). The house rules render in every session, with no "{% include" left. There is no sleep, no check-agent, no getLines repeat and no send caller. Small: the `{% if tools.agents.enabled %}` "schedule an agent" line also shows in agents with `disallowedTools: [agents]` (planner, double-check), because the gate reads the session config and not the agent''s resolved tools. Either a per-agent template value (e.g. `agent.tools.agents`) in Agents, or move the line to the agents that have the tool.'
  timestamp: 2026-11-10T23:09:34.194129+00:00
- actor: claude-code
  id: 01m746apfwzzyyxmvj8931xyyb
  text: 'oneplan24, 3/3 resolved so far. 13925: the plan check said REVISE (proven with a monkeypatch run and the released Django 3.2 package), then a new planner, a check PASS, coder, tester, change check and RESOLVED, in 7058 s (planner24 4381 s). The REVISE round costs time but caught a wrong rule. Still open: a second committer for `.kanban/` remains (13925). do-task finalizes the kanban task (last comment, move to Done) AFTER the work commit, so the board changes again. Fix in do-task: finalize the board first, then make ONE commit at the end (code + tests + .kanban/). Or let the committer of the finalize step be the only one.'
  timestamp: 2026-11-11T02:17:27.804507+00:00
- actor: claude-code
  id: 01m74h4xyg4gy3yk6nbqw0eq1r
  text: 'oneplan24 13964 hit TOO SLOW (9636 s), and the agent did NOT honor `session/cancel`. At the limit the harness sent cancel (root 05:15:02 UTC: "mail ... cancelled"), but the turn did not end until the harness closed the process 600 s later (05:25:03 "answer ended"). The root''s child coder was running the full suite in the background, so the session kept work and sent no `cancelled` idle. Expected: a cancel of the root session cancels its running child agents and their background commands, and the turn ends with `cancelled` within seconds. Write a failing test first: a root with a running child plus a background command, then session/cancel, then expect the cancelled idle quickly. Owner: ACPAgent (cancel path), maybe Agents (cancel of the runs of a caller). Also in 13964: the second coder spent about 40 min in the test setup (unittest/case.py, runner.py, /tmp probes), and re-ran pending tests 3 times (seq 12043 > 12308 > 12419 > 13460). House-rule additions for after the run: "do not start the same command again while its result is pending", and "if the tests of the changed module pass and a failure is in the test setup, report it and stop".'
  timestamp: 2026-11-11T05:26:33.168070+00:00
- actor: claude-code
  id: 01m75bw5e8aqf5eabaxsrz9ee5
  text: 'Decided (user, 2026-11-11): cancel is a command, close to kill. Fix after oneplan24: `session/cancel` must stop ALL work the session started (child agent runs, their background shell commands), not only `cancelForeground()`; the one exception is scheduled agents. The `cancelled` idle must come within seconds. Code: Sources/FoundationModelsACPAgent/Agent/PromptExecution.swift `cancelRunningPrompt`, which today calls `entry.session.cancelForeground()` and spares background runs on purpose (doc cites ^9xs24pn, Q2, G6). Replace that rule. Test first: a root with a running child agent plus a background command, then session/cancel, then expect the cancelled idle within a few seconds and the child run cancelled. Check quit/close paths for the same dithering.'
  timestamp: 2026-11-11T13:13:37.480064+00:00
- actor: claude-code
  id: 01m77qc1x02471f5239daa7ecq
  text: 'Closed 2026-11-12. Done: the build (Extras, Agents 7ad4293/b5fbe7b, Router 864f7290, Multitool 6e648dc2 adopted), one planner + plan check + change check, r.errors, .kanban/ in the same commit, no re-check of the plan by the root, no status mail, no polling, scratch logs outside the repo (skills 85d1dd7), the scheduled-agent work lease (e61c18c), scan.py recovery (647c7de), the one-planner experiment (oneplan24, 22/24). Decided no change: tester full suite, verb hint. Dropped: shorter root turns, snapshot race. Still open, moved to the oneplan24 follow-up card: the "schedule an agent" line gate, the end-to-end scheduled-agent test.'
  timestamp: 2026-11-12T11:13:01.344254+00:00
position_column: done
position_ordinal: ffffda80
title: 'After planner24: build, skills and follow-ups from the run'
---
Items collected while watching the planner24 SWE-bench run (2026-11-09/10). Do them after the run ends; no rebuild while it is live.

## Build
- [ ] Take Extras d5a812f (includes 1935608: raw newline in a string, unused variable, String/ID variable coercion) and Agents d15afb5; rebuild
- [ ] Adopt Router main GGUF/llama.cpp (pushed 2026-11-10, breaking; `swift package update` after pulling):
  - every target that depends on Router (directly or transitively) needs `.interoperabilityMode(.Cxx)`: trailing loop in Package.swift `for target in package.targets where target.type != .plugin { target.swiftSettings = (target.swiftSettings ?? []) + [.interoperabilityMode(.Cxx)] }`
  - model references are now `owner/name/<path in repo>[@revision]`: update ModelReferenceFormat; GGUF routes to llama.cpp; MTP detected from nextn layers; `drafter:` names a drafter checkpoint (type from metadata)
  - `MLXFoundationModelsContainer` is renamed `LiveLLMContainer`; it holds `any LanguageModel`; use `.mlxModel` for the MLX model
  - CI will be red until this lands: since workflows d659d39 CI runs `swift package update` and pulls Router main. Do not push to main before this is adopted.

## Skills repo (../skills)
- [ ] do-task (`skills/do-task/references/code.md`) and default agent: run ONE planner, not two. The root starts one planner, reads its plan, and hands it to one coder. Evidence from planner24 (14 instances with planners): the two planners named the same root cause in every instance; the fix matched in substance in ~7–8, differed in mechanism in 4 (14016, 14155, 14382, 14667), and 3 could not be judged. All 3 that differed and resolved would likely have resolved with either plan; in the one miss (14667) both planners had the same wrong rule ("load only the pk" vs. the expected "clear the restriction, load all fields"), so a second planner could not save it. Planning was 48% of the wall time and the planner role 48% of decode time. Keep the kanban comment for the plan.
- [ ] (with the item above) consider using the freed time for a plan check instead: before the coder starts, a check of the plan against the existing tests of the functions it changes (would have flagged 14667: `tests/defer/tests.py` already pins the "clear and load all" rule)
- [ ] kanban skill: check `r.errors` before `r.data` (4 of 6 kanban errors crashed on `r.data`)
- [ ] kanban / do-task: `.kanban/` is valuable metadata and is committed. Commit it together with the work (one committer run), not in a separate commit step afterwards (14608 started a second committer just for it). The bench harness already keeps `.kanban` out of the scored patch (cbd7324).
- [ ] default agent: when plans disagree, do not check them yourself; give both to the coder, ranked (14155: 19 root hands-on calls). With one planner this becomes: do not re-check the plan yourself; hand it on
- [ ] tester / coder / planner agents: no status messages to the caller; end the turn with "Waiting on ..." (14017: 11 `send caller` status calls in 5 min, each woke the root)
- [ ] tester / coder agents: no polling of a background command. 14667 coder (session 01M72PQJ1G): full suite in the background, then ~40 calls in 5 min of `sleep 300..600; grep log` probes and getLines checks of them, while its own comment says "I must not poll". End the turn with "Waiting on ..." instead
- [ ] tester / coder agents: write scratch logs outside the repo (14667 wrote `full_suite_run1.log` in the repo root; it can reach the scored patch, and its writes made 38 snapshot-hook failures "libgit2 error -1: file changed before we could read it")
- [ ] tester: run the tests of the changed modules, not the full suite (14017: 2433 s in verify; 14667 full suite again)
- [ ] default agent: shorter turns and shorter agent prompts (root ~1737 tokens per generation, 18% of decode time)

## Peers
- [ ] Multitool: the made-up-verb hint searches only the named group (`fs.getcwd` -> getDiagnostics, `code_context.runShell` -> grepCode); search all groups. Send to the Multitool session.
- [ ] Agents (optional): restored scheduled agents get no work lease. Send to the Agents session.
- [ ] Hooks/snapshots (maybe): a snapshot that races a file being written fails with libgit2 -1; retry once, or skip the changing file with a warning, so the snapshot is not lost

## Experiments
- [ ] After the one-planner skill change: run the same 24 instances (planner24 ids) and compare with planner24 — score per instance and wall time
- [ ] Real end-to-end test of a scheduled agent

## Small
- [ ] scan.py: a made-up-verb recovery that shows in `toolCallStarted` rows counts as "recovered 0" #bench