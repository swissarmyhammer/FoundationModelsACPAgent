---
depends_on:
- 01KY7EEGS0JJ5G6720FGSEBT3M
- 01KY7EEGSF74WKDZBTEYXJ21NW
position_column: todo
position_ordinal: 8a80
title: 'PythonCLIEvaluation: end-to-end coding-agent eval (gated)'
---
Plan §10.1, displaced here with the roster that supplies its tools. Apple's Evaluations framework, gated (Apple silicon + real models + network): fresh temp workspace as cwd/confinement root, real files+shell tools, coding instructions; ArrayLoader of build-a-small-Python-CLI samples (pyproject, third-party dep, pytest green, run it); mechanical re-verified evaluators PytestGreen / CLIRuns / FilesPresent / ToolTraffic; means asserted against thresholds; token usage + turn counts keyed by resolved model. Everything inside the temp workspace, deleted after grading (transcripts retained on failure). DEPENDS on conformance + CLI tasks.