---
name: fixture-explore
description: >-
  Understand unfamiliar code before you change it. Use when the task says
  explore, investigate, how does this work, who calls this, or what does a
  change touch.
license: MIT
metadata:
  author: FoundationModelsACPAgent tests
  version: "1.0.0"
---

# Explore the code

FIXTURE-EXPLORE-BODY

Do the work in this order:

1. `await tools.code_context.listSymbol({ file: "<file>" })` for the table of
   contents of a file.
2. `await tools.code_context.getSymbol({ query: "<symbol>" })` for the source
   of one symbol. Do not read the whole file.
3. `await tools.code_context.getCallgraph({ symbol: "<symbol>", direction: "inbound" })`
   for the callers, before you change a symbol.
