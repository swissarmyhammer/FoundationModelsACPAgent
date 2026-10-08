---
assignees:
- claude-code
depends_on:
- 01M4E2BEVVM2SHK85XG9DGE8CC
position_column: todo
position_ordinal: '8380'
title: 'config path: show the builtin configuration file in the builtin row'
---
## Problem

Task ^9dge8cc ships the builtin configuration as the file `builtin.config.yaml` in the resource bundle of the library. `config path` (`Sources/acp-agent/ConfigCommand.swift`, `Config.Path`) still prints the builtin row as "(in code, no file)", and the `Location.code` doc comment says "the builtin defaults have no file". That text is not true now.

## Decision

The builtin row of `config path` shows the path of the builtin file in the resource bundle (`BuiltinConfigurationFile.url()`), with the "exists" mark, in place of "(in code, no file)".

## Tests

- `config path` prints the builtin row with the path of `builtin.config.yaml`, and the path exists.
- `CLIProcessTests.configPathWritesTheLayerRowsToStdoutAndExitsZero` stays green with the built binary.

#config