---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: Remake the interrupted nested recording with the mxfp4 standard model and answer how a cold resume uses the recorded cwd
---
## What
Request from AgentViewKit (session agentviewkit-20). It copied `Recordings/interrupted-nested-child/workspace/.acp-agent/transcripts` into its demo recordings. The resume fails with `modelMismatch(session: 01M6JKRZ7HWFCD7GFPEETKGX83, slot: standard, recorded: mlx-community/Qwen3.8-27B-4bit with drafter mlx-community/Qwen3.8-27B-MTP-4bit, resident: mlx-community/Qwen3.8-27B-mxfp4, no drafter)`. The Gallery stage names `mlx-community/Qwen3.8-27B-mxfp4` as the standard model and all other recordings used it, so the stage cannot change.

## Do
1. Change `Recordings/interrupted-nested-child/make.py` so that the recording uses the `standard` model `mlx-community/Qwen3.8-27B-mxfp4` with NO drafter. Find where the isolated config of the script sets the model and the drafter (the profile or config line in its isolated config); add a model argument (default `mlx-community/Qwen3.8-27B-mxfp4`) or a config line. The stub model must still play the script (the recording holds the model id only as metadata). Update the README of the folder (in ASD-STE100 Simplified Technical English).
2. Make the new recording AFTER commit bb8cc3b (it is on origin/main) so it holds the paused `agents` calls (the quit pause of ^q4zy0hz and ^d6vzdkg). Check the result by reading the transcripts: the root's `agents` call has no final status (paused), the child and the grandchild have `agentSpawn`, no `endedAt` anywhere, the recorded model of the `standard` slot is the mxfp4 id with no drafter. Replace the old recording in the folder (delete the old workspace transcripts of the previous root id; the README table must show the new session ids).
3. Answer in a comment on this card (in ASD-STE100 Simplified Technical English) and in your report: does a cold resume of the children still work when the recorded `cwd` (an absolute path in this repo, `.../Recordings/interrupted-nested-child/workspace/`) does not exist on another machine, with the agent definitions `parent` and `leaf` found in the USER layer (not in the cwd)? Read the code: the restore path (`SessionResume.swift`, `SessionResumeNested.swift`, `restoreSessionWithHostChecks`, the Agents package `AgentRunner.restoreInterrupted` and how it finds the definition registry and the directory), and what the host does with a missing recorded cwd. If it needs the cwd, say exactly where it is used, and advise: for example a make.py option that records with a relative or a portable cwd, or a note that the demo must create that directory. Do NOT change production code in this task; if a production change is needed, write it as a finding and stop.
4. Unit tests: none needed unless you change code. The recording is made by running the stub (a manual diagnostic run of the script is allowed; do not run the IntegrationTests package).

## Acceptance Criteria
- [ ] `make.py` records with the mxfp4 standard model and no drafter, by default.
- [ ] The committed recording holds paused `agents` calls and the mxfp4 model.
- [ ] The comment on this card answers the cwd question, with file:line.

## Workflow
- #subagents