---
assignees:
- claude-code
position_column: done
position_ordinal: '80'
title: A continue sends the source row again on externalSessionChanges, with the new copy
---
Source: Testudo ^bq170kn, brief .briefs/FoundationModelsACPAgent-copy-changes-source-row-2026-11-23.md.

After `copySession(of:folder:name:)` adds a copy to `ExternalSessionContinuations`, no subscriber of `externalSessionChanges(folder:)` gets the source row. So an open read-only tab does not show the new "Continued <date>" until it opens again.

## Fix
- [x] The index publishes the row of one read session again, with no read (`ExternalSessionIndex.republish(matching:of:)`). The folder filter of the index and the decoration of the host relay apply as for each change.
- [x] `copySession` calls it after `continuations.add`.

## Tests
- [x] A subscriber of the folder of the source, and a subscriber of each folder, get the source row with the new copy after a continue. #bug
## Result
- Before the fix, the two cases of the new test waited for ever for the change. After the fix, they pass.
- Multitool gives the host stream with no change, so it needs no change.
- The full suite: 2850 tests pass, with 1 known issue.
