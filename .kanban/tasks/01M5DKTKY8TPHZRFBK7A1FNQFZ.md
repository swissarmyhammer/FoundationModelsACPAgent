---
depends_on:
- 01M5CZ4EDEW6ECQ13W9E7QFTFW
position_column: todo
position_ordinal: '8e80'
title: The settings endpoint reads and writes the user level with no cwd
---
## What
D98(a) and D100(d): the Settings scene of the app writes only the user level, through the `settings` endpoint. It has no working folder. Now (cards ^cj9s5j0 and ^e7qftfw) the endpoint refuses a call with no `cwd` with the code `MISSING_CWD`, also for `set` and `clear` on the `user` level, and the `setting` query always gives the merged value of a cwd.

Do this:
- `set` and `clear` with `level: user` need no `cwd`. With `level: session`, `cwd` stays required on the endpoint (`MISSING_CWD`), and the session tool keeps its own folder.
- A query with no `cwd` gives the value of the user level merged over the built-in layer (no session level), and the level that set it (`user` or the built-in level). Give the built-in level a name in the schema if it has none.
- The `changes` subscription with no `cwd` gives the changes of the user level.
- Update the golden schema `Tests/Fixtures/settings.graphql` and the doc comments.

## Acceptance Criteria
- [ ] A user-level `set` and `clear` with no `cwd` work on the endpoint and write `<root>/config.yaml` (or the XDG user file for the CLI).
- [ ] A query and a subscription with no `cwd` give the user-level values.
- [ ] A session-level call with no `cwd` on the endpoint still gives `MISSING_CWD`.

## Tests
- [ ] A test for each criterion with temporary folders.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-17