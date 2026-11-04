---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Stub script step "permission": the run sends session/request_permission and waits for the outcome, also in a child run'
---
## What
Request from the ACP client session (foundationmodelsacpclient-11). It blocks the client card ^kg9t45m, items B1 and B2. Today the stub script has the steps `text`, `reasoning`, `toolCall`, `gate` and `elicit` (see `Sources/FoundationModelsACPAgent/Configuration/ScriptedStubScript.swift`). No agent code calls `requestPermission`.

Needed: a step `{"permission": "<title>"}`. The run sends `session/request_permission` to the client, waits for the outcome, and goes on after it. A cancelled outcome ends the pass (as `elicit` does with a decline or a cancel). It must work in a CHILD run too, so that the client can check that the request shows under the child session id exactly once and never under the root.

## Do
1. Read how `elicit` works end to end (`ScriptedPassStep.elicit`, `ScriptedSessionBackend.askUser`, `ScriptedElicitation`, `ElicitationRelay` / `ElicitationClaims`, the child elicitation under the child session id of ^my9mbdf). Find what the host has to send a permission request to the client under a given session id: the ACP connection API for `session/request_permission`, its request and response types in the FoundationModelsACP package, and how a child session id is used as the session id of the request (a child is its own session on the wire).
2. Add the step `permission` to the script grammar (`ScriptedStubScript`, a `ScriptedPassStep` case, the playbook), parse and document it in the grammar comment at the top of `ScriptedStubScript.swift`. The request carries the title and a small set of options (allow once, reject once, or whatever the ACP schema in the checkout defines; read it). The outcome is one of: selected option (the pass goes on), cancelled (the pass ends, as for `elicit`).
3. In a child run, the request goes out under the child session id, exactly once, never under the root. Use the same routing as the child elicitation (claims, relay). Cancel semantics: `session/cancel` of the child while a permission request is pending cancels the request (the outcome is cancelled).
4. Do not change a sibling package; if a host API is missing in FoundationModelsACP, mark the task stuck and say exactly which.
5. Docs: add the step to the stub script section of README.md (ASD-STE100 Simplified Technical English).

## Acceptance Criteria
- [ ] A script with `{"permission":"..."}` in the root session sends exactly one `session/request_permission` under the root id, waits, and plays the rest after a selected outcome.
- [ ] A cancelled outcome ends the pass.
- [ ] In a child run, the request shows under the child session id exactly once and never under the root id.
- [ ] `session/cancel` of the child while a request is pending ends the request with the cancelled outcome.
- [ ] The grammar comment and the README name the step.

## Tests
- [ ] Unit tests over the in-process wire (the existing fixtures with a scripted client that answers or cancels the request), including a child run with a gate/hold so that the request is pending when the cancel arrives.
- [ ] Run the touched unit suites. Do NOT run the IntegrationTests package (CI only).

## Workflow
- Use `/tdd`. #subagents