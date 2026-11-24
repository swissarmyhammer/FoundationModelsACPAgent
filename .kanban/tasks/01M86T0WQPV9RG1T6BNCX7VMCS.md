---
assignees:
- claude-code
position_column: done
position_ordinal: '8180'
title: 'Resume history: no lost turn when the file has fewer turns, or for a copied external session (Testudo ^fgbds9q)'
---
## Problem

- (a) A history file can have fewer turns than transcript.jsonl: a build before ACPAgent 44850640 wrote the file only at the end of a turn and at session/close. A stop of the process during a turn lost that turn. A resume reads the file and replays no turn of the journal that the file does not hold.
- (b) A copied external session (Claude Code or Codex) has a journal whose `.prompt` entries hold no mail record. When its history file is missing or does not decode, the rebuild gives no user message for these prompts. Thus the replay loses the user side of each copied turn.

## Fix

- (a) After the read of a file, the agent rebuilds the journal. Each journal turn that starts with a user mail, that the file does not hold, and that comes after the last turn that the file holds, goes at the end of the file transcript.
- (b) The rebuild gives a user message for a `.prompt` entry with no mail record and no compaction. Its id is the id of the entry, so each rebuild gives the same id.

## Tests

- A file with one turn of a journal with two turns replays the two turns.
- A copied external session with no history file replays its user messages.
## Result

- (a) `RecordedHistoryMerge` adds each journal turn of a user mail after the last turn that the file holds. Test: `aFileWithFewerTurnsReplaysEachTurnOfTheTranscript`.
- (b) A copied session with its history file replays the full source (the existing test). With no file, the rebuild now gives the user message of each copied prompt (origin `import`). Tests: `aCopiedPromptGivesAUserMessageWithTheIdOfItsEntry`, `theResumeWithNoHistoryFileReplaysTheUserMessages`. Each fails without the fix.
- Limit: with no file, a copied turn shows each tool call as text in the agent message, and it shows no thought: the journal of a copy holds only that text.
