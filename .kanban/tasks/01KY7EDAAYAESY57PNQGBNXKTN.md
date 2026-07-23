---
depends_on:
- 01KY7ECSJGTV23JVX3D4AXZGQM
position_column: todo
position_ordinal: '8280'
title: 'Instructions assembly: base prompt + AGENTS.md + config replace/append'
---
Plan §6.1. Per session, keyed to its cwd: base = instructions.replace else defaults-dir Instructions.md; then user-level ~/.config/<name>/AGENTS.md via DotfolderStack.content; then project-level AgentsMd.documents(from: cwd) — outermost-first, nearest wins (BLOCKED cross-repo on Extras task 67w7zj6 AgentsMd, still pending); then instructions.append. Each file delimited by a header naming its absolute path (attribution); missing files absent, unreadable = logged warning not error; each document renders untrusted through Extras' engine first. Result folds into the instructions value handed to makeSession — Router never knows.