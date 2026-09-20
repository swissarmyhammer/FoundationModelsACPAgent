---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2x3zghfqzknd1fesm74ttac
  text: |-
    ### implement — done

    - The library of the tests is `Tests/Fixtures/skills/`, with a `README.md` that says what each skill proves: `fixture-explore` (visible, body names the `tools.code_context` verbs), `fixture-release-notes` (a second visible skill), `fixture-hidden` (`disable-model-invocation: true`).
    - `Tests/FoundationModelsACPAgentTests/Integration/SkillsLibraryTests.swift` finds the library through `PackageRoot` and copies it into `<cwd>/.skills/` of each test session. No network, no marketplace, no model download.
    - Six proofs: the mounted tool carries each visible skill and no hidden one; the `id` parameter is the enum of the visible ids; a disabled section mounts no tool; a `use skill` call gives the text of the `SKILL.md` body with no JSON around it; a search gives the plain lines and names the load call `{"op": "use skill", "id": "fixture-explore"}`; a hidden id loads no body.
    - One fact the tests found: the projection of a tool result puts the String answer on the wire as JSON, thus a plain-text answer arrives quoted and escaped. The reader decodes it, and the doc comment says why.
    - `swift test`: 583 tests passed. Bench tests: OK.
    - Not in this card: whether a live model CHOOSES to load a skill. That needs the trigger evaluation of the follow-up card.
  timestamp: 2026-09-19T15:18:55.791385+00:00
position_column: done
position_ordinal: e580
title: Integration tests that prove a skill loads, over a skills library in this repository
---
## What

Three SWE-bench runs showed that nobody can say from this repository whether a skill loads. Each check needed a run of hours, a marketplace fetch over the network, and a reading of the transcripts by hand. The agent has no test that mounts the `skills` tool and proves that a skill reaches the model.

## The work

1. **A skills library of this repository, as test artifacts.** A new directory, for example `Tests/Fixtures/skills/`, with a few small skills, each one a `SKILL.md` with front matter:
   - one skill that names the `tools.code_context` verbs, as the code context skill does;
   - one skill for another kind of work, so a search must choose;
   - one skill with `disable-model-invocation: true`, which the model must not see.
   The files are read from the repository by a path from `#filePath`, as the other fixtures of this suite do. No network and no marketplace.
2. **A tier-2 suite** that mounts the real surface through `ToolCatalog`, with the skills stack rooted at that directory, and proves:
   - the description of the mounted `skills` tool holds the id and the description of each visible skill, the load rule, and no hidden skill;
   - the `id` parameter is the enum of the visible ids;
   - a scripted model that calls `{"op": "use skill", "id": "<id>"}` gets the body of that `SKILL.md`, word for word, as plain text with no JSON around it;
   - the same text reaches the wire and the transcript, so the model really has the procedure;
   - `search skill` gives the plain lines and names the load call;
   - an unknown id gives a plain correction, and the turn continues.
3. **A test of the refusal:** with `tools.skills: false` there is no `skills` tool, and no skill text reaches the model.
4. The suite runs in `swift test` with no network, no model download and no marketplace.

## Why here

The Skills package tests its own operations. This suite proves the composition of THIS agent: the dotfolder stack, the tool catalog, the wire and the transcript. A change of the Skills API, of the description or of the output shape then breaks a test here in seconds, and not in a run of hours.

## Later, a separate card

A tier-4 trigger evaluation with the live model: approximately 20 prompts, 3 runs each, and a measured rate of how often the model loads a skill. That answers "does the model use a skill", which this card does not. #skills #tests