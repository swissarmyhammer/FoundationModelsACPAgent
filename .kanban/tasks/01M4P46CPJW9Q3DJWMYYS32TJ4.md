---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p4707k45p15tbtmvjyk2ss
  text: |-
    ### Sibling tasks (2026-10-11)
    - FoundationModelsMultitool ^1dzf1za (01M4P465D86TRZBJ1V81DZF1ZA): one shared pending text for all background-work places.
    - FoundationModelsMultitool ^9pnyvyp (01M4P46MBNPN4MWKZKE9PNYVYP): mark a runCode call that calls no tools.* verb as a no-op (information only).
    - FoundationModelsRouter ^rw72f4j (01M4P46A27T975CVFXYRW72F4J): stop the generation on a no-op tool call while an operation is pending. Depends on the mark of ^9pnyvyp.
    - FoundationModelsAgents ^24nf9ss (01M4P46GJ5WZ7Q3E9NH24NF9SS): the same text for start agent. It removes the instruction to call {"op": "check agent"} from the pending text.
    - next: start item 3 of this task (bench check) only after all four are done and pushed.
  timestamp: 2026-10-11T18:39:43.859216+00:00
position_column: todo
position_ordinal: '80'
title: 'Use the injection model for pending work: README, detectProjects settle, bench check'
---
## Why

The SWE-bench run `no-otel-1011` (2026-10-11) found a model loop when work is pending:

- `django__django-13964`: a `runCode` call of `tools.code_context.detectProjects` went pending. Then the model made 73 no-op `runCode` calls (`return "waiting placeholder"`, `return null`, `return "end 11"`, ...), from seq 2027 to 2319. Only the Router repetition watch stopped it (`watchStop finish=repeatedLines`).
- `django__django-13447`: an inner `tools.shell.execute` went pending. The snippet read `s.output` (undefined) and failed. The model sent the same 1006-test command again, so 2 copies ran in parallel.

The user decided: there are no turns, only async queues. The result of pending work is injected into the session as a new message, and that message starts the model working again. Parallel tool calls stay free. If no other work can be done, the model does nothing. There is no wait tool.

## Sibling tasks (requested from the peer sessions)

- FoundationModelsMultitool: one shared pending text in all places; mark a `runCode` call with no `tools.*` verb.
- FoundationModelsRouter: while work is pending, a no-op call stops the generation, and the session does not run or answer it.
- FoundationModelsAgents: the same text for `start agent`.

## Work in this repo

1. Update the README: replace "There is no `wait` tool. A `runCode` run that does not settle in its inline grace continues in the background, and its result comes back to the session as mail when it settles." with the injection model, in the approved words.
2. Find out why `tools.code_context.detectProjects` went pending in `django__django-13964` (it must settle inside `inlineSettleGrace`). Fix it here, or request a task from the CodeContext session.
3. After the sibling tasks are done, `swift package update`, then run a bench check.

## Acceptance criteria

- The README tells the injection model, and it does not say "end your answer".
- `detectProjects` settles inline on a Django clone, or a sibling task exists for it.
- A bench run of at least 5 instances has 0 no-op `runCode` loops (no instance with more than 8 no-op calls) and 0 duplicate test commands that a pending result caused.

## Tests

- The bench run in item 3 is the check. Use `scan.py` and count the `runCode` calls whose snippet calls no `tools.*` verb. #bench