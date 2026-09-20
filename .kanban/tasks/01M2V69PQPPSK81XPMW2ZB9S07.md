---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2v8pjenregsga7pqafmrbwf
  text: |-
    ### Research — blocked on Router

    - Router has no seam to protect a tool output. `Compactor.stages` is a fixed internal list: `[ToolOutputElision(), TurnTruncation()]` (`Compaction/Compactor.swift:90`).
    - `ToolOutputElision` replaces every `.toolOutput` entry older than the recency window with `[elided: original "<tool>" output omitted by compaction]`. It has no exemption.
    - A host gives only `TokenBudget`, `CompactionPrompt` and `Summarization`, and none of them can mark an entry.
    - Thus, as this card says in step 1, I stopped here and made card `^ebftpem` on the FoundationModelsRouter board: "A host cannot keep a tool output through compaction, so a loaded skill is elided".
    - Next step here, after `^ebftpem` is done: give the session the Router rule that protects each `skills` output of `op: "use skill"`, and add the test of step 4. No change in this repository until then.
  timestamp: 2026-09-18T22:02:56.853141+00:00
- actor: claude-code
  id: 01m2vdfanbrf7025pjpbq0kqbf
  text: |-
    ### implement — done

    - Router `^ebftpem` is pushed (origin/main 6581750, after a full `swift test` in a separate worktree: 1343 + 1 + 83 passed). `swift package update` pins Router 6581750 and Skills 857f0b0.
    - New `SkillOutputProtection` (Sources/FoundationModelsACPAgent/Tools/SkillOutputProtection.swift): the `ToolOutputProtection` rule protects a `skills` call whose `op` is `use skill` or a verb alias of the skills resolver (`call`, `invoke`, `get`). It reads the call, not the output text; no marker is added.
    - The rule goes to `makeBudgetedSession` (the one door of `session/new` and the model-slot switch) and to `restoreSession` in `SessionResume`.
    - Test support: `ScriptedSessionBackend.replacingTranscript(_:)` now continues from the folded transcript. Without it, the protocol default ignored the fold, and a scripted session never showed a compaction.
    - Tests: `SkillOutputProtectionTests` (the rule for each op form and other tools; a session from `makeBudgetedSession` with 6 turns keeps all 6 skill bodies word for word after a fold, and fewer than 6 notes outputs keep their text). With the rule set to nil, the session test fails, so it proves the wiring.
    - `swift test`: 577 tests passed. Bench tests: OK.
  timestamp: 2026-09-18T23:26:22.379454+00:00
position_column: done
position_ordinal: e480
title: Keep the body of a loaded skill when the context is compacted
---
## What

When the context of a session is full, Router folds older transcript entries into a summary. The body of a skill that the model loaded with `use skill` is a tool output, so a fold can remove it. The model then continues with no procedure and no visible error.

The Agent Skills standard says: "Skill instructions are durable behavioral guidance — losing them mid-conversation silently degrades the agent's performance without any visible error." It recommends that a host exempts skill content from pruning. Source: https://agentskills.io/client-implementation/adding-skills-support

## The work

1. Find how a Router compaction stage selects the entries that it folds, and if a host can mark a tool output as protected. If Router has no such seam, make a card in FoundationModelsRouter and stop here.
2. Mark each `skills` tool output of the `use skill` operation as protected, so a fold keeps it.
3. Do not add a tag or a wrapper to the body. Find the entry by its tool name and operation.
4. A test: a session with a scripted model loads a skill, the compaction runs, and the skill body is still in the transcript.

Follows card `^6kwck9t`. #skills #compaction