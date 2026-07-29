---
depends_on:
- 01KY7EDAAEV7M16J19CESQ54ZR
position_column: todo
position_ordinal: '8480'
title: 'MCP roster lane: mcp entries → MCPToolProvider'
---
Plan §4/§7 + head decision. Each mcp entry passes through to FoundationModelsMCP's MCPToolProvider and yields [any Tool] merged into the session roster. Transport is the MCP package's job: command spawns and owns the stdio subprocess; url makes an http/s client connection; lifecycle, reconnects, and pooling across sessions are UPSTREAM ASKS on FoundationModelsMCP (record them on that repo's plan/board — not yet done anywhere). Templated env values (e.g. {{ env.GITHUB_TOKEN }}) already resolved by config rendering. This package never manages a process.