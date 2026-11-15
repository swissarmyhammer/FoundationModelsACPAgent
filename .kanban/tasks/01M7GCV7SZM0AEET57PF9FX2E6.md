---
assignees:
- claude-code
position_column: done
position_ordinal: ffffed80
title: 'Make the no-op rule narrow: mark only stand-by runCode snippets'
---
From TestudoApp (testudoapp-75). Defect: `NoOpToolCall.isNoOp` marks each runCode snippet that calls no `tools.*` verb as a no-op. Router blocks it also when no work is pending. Example: `const now = new Date(); return now.toString();` for "what is today" gave no answer.

Fix: use `MultiTool.isStandbySnippet(_:)` (empty, `return;`, return of one constant). Fix the doc comment (Router no longer checks only while an operation is pending).

Tests: a `new Date()` snippet is not a no-op; `return "waiting-3"` is a no-op.