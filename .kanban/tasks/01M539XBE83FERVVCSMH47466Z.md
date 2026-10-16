---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53az7h5sa1rscx8c01km0w5
  text: 'Done. Package.resolved is in .gitignore, so the move gives no commit; CI resolves the head of each sibling main (ACP 7890129, Extras 1804680 at this time). Local full run on the new pins: 977 tests in 109 suites, green.'
  timestamp: 2026-10-16T21:47:56.837922+00:00
position_column: done
position_ordinal: ffe580
title: 'Move pins: FoundationModelsACP 7890129, Extras 1804680'
---
Move Package.resolved to FoundationModelsACP 7890129 (R2 on the wire: no request after its own cancel) and FoundationModelsExtras 1804680 (R1: a cancelled token asks no new question; D-1: pattern and length follow JSON Schema). Build, then do one full test run. Source: elicitation-plan.md section 10. #elicitation