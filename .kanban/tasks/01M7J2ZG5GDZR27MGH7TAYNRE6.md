---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Give the machine-local usage store to the session directory
---
BLOCKED until Router has `SessionUsageStore`, its JSON file and `RouterSessionDirectory.use(usageStore:)` (the Router owner, another machine).

- Make the store at `AgentHome.local`, for example `<local>/sessions/usage.json`. It is the state of this machine and never syncs (D118 (e), TestudoApp 87e17ac).
- Give it to `router.sessionDirectory` in the `RoutedACPAgent` initializer, next to `use(launcher:)`.
- Test: a pin and a markUsed survive a new agent over the same home; two homes do not share pins. #blocked