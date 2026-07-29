---
depends_on: []
position_column: todo
position_ordinal: '8880'
title: 'acp-agent CLI: stdio serving + stdout purity (gated)'
---
Plan §9/§9.1. The executable lane: serve the conformance over ndJSON stdio — stdout sacred (nothing but ACP frames), logs to stderr. Gated integration test: run the CLI, execute a real shell-tool turn (subprocesses in-process), assert every stdout byte parses as ndJSON — the hazard tested, not assumed. This binary is also the production CLI's acp mode; interactive frontends consume the composition object directly. DEPENDS on the conformance task.